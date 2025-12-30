import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'fare_config.dart';

class _GpsSample {
  final double lat;
  final double lng;
  final double accuracy;
  final double speed;   // m/s
  final double heading; // degrees
  final DateTime time;

  const _GpsSample({
    required this.lat,
    required this.lng,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.time,
  });
}

class TaximeterController extends ChangeNotifier {
  final FareConfig config;

  bool running = false;

  Shift shift;
  ServiceChannel channel;

  double distanceMeters = 0;
  final Stopwatch _stopwatch = Stopwatch();

  // Último punto "real" aceptado para cálculo de distancia y ruta naranja
  _GpsSample? _lastAccepted;

  // Posición actual (filtrada) para UI (tracking cámara / marcador)
  Position? currentPosition;

  StreamSubscription<Position>? _sub;
  final List<LatLng> traveledPath = [];

  Timer? _ticker;

  // ------------------------
  // Filtros / parámetros
  // ------------------------

  // Ventana para filtro mediana
  static const int _medianWindowSize = 7;
  final List<_GpsSample> _window = [];

  // Rechaza lecturas con accuracy peor a esto (metros)
  static const double _maxAccuracyMeters = 35.0;

  // Velocidad máxima taxi: 200 km/h -> 55.555 m/s
  static const double _maxSpeedMps = 200.0 / 3.6;

  // Margen para el límite máximo (por si timestamps/heading/speed son raros)
  static const double _maxSpeedMargin = 1.15; // 15%

  // Distancia mínima base (m) para considerar "avance real"
  // (el umbral final será dinámico según accuracy)
  static const double _minMoveBaseMeters = 3.0;

  // Para evitar aceptar saltos gigantes tras mucho tiempo sin aceptar puntos,
  // pon un techo opcional (0 = sin techo). Ajustable.
  static const double _absoluteMaxJumpMeters = 0.0; // ej. 3000.0 si quieres

  TaximeterController(
      this.config, {
        this.shift = Shift.diurno,
        this.channel = ServiceChannel.calle,
      });

  Duration get elapsed => _stopwatch.elapsed;

  int get units => config.unitsFromTotals(distanceMeters: distanceMeters, elapsed: elapsed);

  double get fare => config.fareFromTotals(
    shift: shift,
    channel: channel,
    distanceMeters: distanceMeters,
    elapsed: elapsed,
  );

  bool setShift(Shift s) {
    if (running) return false;
    shift = s;
    notifyListeners();
    return true;
  }

  bool setChannel(ServiceChannel c) {
    if (running) return false;
    channel = c;
    notifyListeners();
    return true;
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!running) return;
      notifyListeners();
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  // ------------------------
  // Mediana (lat/lng/accuracy/speed/heading)
  // ------------------------

  double _medianOf(List<double> values) {
    final v = [...values]..sort();
    final n = v.length;
    if (n == 0) return 0.0;
    final mid = n ~/ 2;
    if (n.isOdd) return v[mid];
    return (v[mid - 1] + v[mid]) / 2.0;
  }

  _GpsSample _medianSample(List<_GpsSample> samples) {
    return _GpsSample(
      lat: _medianOf(samples.map((s) => s.lat).toList()),
      lng: _medianOf(samples.map((s) => s.lng).toList()),
      accuracy: _medianOf(samples.map((s) => s.accuracy).toList()),
      speed: _medianOf(samples.map((s) => s.speed).toList()),
      heading: _medianOf(samples.map((s) => s.heading).toList()),
      // Para tiempo usamos el más reciente (mejor para dt)
      time: samples.map((s) => s.time).reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }

  double _minMoveThresholdMeters(double accuracyMeters) {
    // Umbral dinámico:
    // - mínimo 3m
    // - crece con accuracy para matar jitter (ej. accuracy 20m -> umbral ~12m)
    // - cap opcional a 20m para no matar tráfico lento
    final dyn = accuracyMeters * 0.6;
    return max(_minMoveBaseMeters, min(20.0, dyn));
  }

  double _maxAllowedJumpMeters(Duration dt) {
    final seconds = max(1.0, dt.inMilliseconds / 1000.0);
    var maxDist = _maxSpeedMps * seconds * _maxSpeedMargin;

    if (_absoluteMaxJumpMeters > 0) {
      maxDist = min(maxDist, _absoluteMaxJumpMeters);
    }
    return maxDist;
  }

  Future<void> start() async {
    if (running) return;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      throw Exception('Ubicación desactivada (GPS). Actívala e intenta de nuevo.');
    }

    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      throw Exception('Permiso de ubicación no concedido.');
    }

    running = true;
    distanceMeters = 0;
    traveledPath.clear();
    _window.clear();

    final first = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    final t0 = first.timestamp ?? DateTime.now();

    final firstSample = _GpsSample(
      lat: first.latitude,
      lng: first.longitude,
      accuracy: (first.accuracy.isFinite ? first.accuracy : 999.0),
      speed: first.speed.isFinite ? first.speed : 0.0,
      heading: first.heading.isFinite ? first.heading : 0.0,
      time: t0,
    );

    _lastAccepted = firstSample;
    _window.add(firstSample);

    currentPosition = first;
    traveledPath.add(LatLng(first.latitude, first.longitude));

    _stopwatch
      ..reset()
      ..start();

    _startTicker();

    // Consejo: si sigues viendo jitter, baja a 2 o 0 y deja que el filtro haga el trabajo.
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) {
      if (!running) return;

      // 1) filtro por accuracy (descarta basura)
      final double acc = (pos.accuracy.isFinite ? pos.accuracy : 999.0);
      if (acc > _maxAccuracyMeters) return;

      final now = pos.timestamp ?? DateTime.now();

      final raw = _GpsSample(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: acc,
        speed: pos.speed.isFinite ? pos.speed : 0.0,
        heading: pos.heading.isFinite ? pos.heading : 0.0,
        time: now,
      );

      // 2) filtro mediana
      _window.add(raw);
      if (_window.length > _medianWindowSize) {
        _window.removeAt(0);
      }

      final filtered = (_window.length >= 3) ? _medianSample(_window) : raw;

      // Actualiza currentPosition para UI (aunque no aceptemos para ruta)
      currentPosition = Position(
        latitude: filtered.lat,
        longitude: filtered.lng,
        timestamp: filtered.time,
        accuracy: filtered.accuracy,
        altitude: pos.altitude,
        heading: filtered.heading,
        speed: filtered.speed,
        speedAccuracy: pos.speedAccuracy,
        floor: pos.floor,
        isMocked: pos.isMocked,
        altitudeAccuracy: pos.altitudeAccuracy,
        headingAccuracy: pos.headingAccuracy,
      );

      final last = _lastAccepted;
      if (last == null) return;

      final dt = filtered.time.difference(last.time);
      final dtSafe = dt.isNegative ? const Duration(seconds: 1) : dt;

      final d = Geolocator.distanceBetween(
        last.lat,
        last.lng,
        filtered.lat,
        filtered.lng,
      );

      // 3) descartar distancias pequeñas (ruido)
      //    No actualizamos _lastAccepted -> nos quedamos con el último punto real.
      //    En tráfico lento, el d va "acumulando" respecto al último aceptado y terminará pasando el umbral.
      final minMove = _minMoveThresholdMeters(filtered.accuracy);
      if (d < minMove) {
        // no dibuja línea naranja ni suma distancia
        // pero sí mantiene currentPosition para follow camera si quieres
        notifyListeners();
        return;
      }

      // 4) límite máximo por velocidad 200km/h (con tiempo acumulado desde último aceptado)
      final maxJump = _maxAllowedJumpMeters(dtSafe);
      if (d > maxJump) {
        // GPS está muy dañado / salto imposible: descartar
        // No actualizamos _lastAccepted, así el dt crece y permite "corregir"
        // cuando el GPS vuelva a un punto consistente.
        notifyListeners();
        return;
      }

      // 5) aceptar punto "real"
      distanceMeters += d;
      traveledPath.add(LatLng(filtered.lat, filtered.lng));

      _lastAccepted = filtered;

      notifyListeners();
    });

    notifyListeners();
  }

  Future<void> stop() async {
    if (!running) return;

    running = false;
    _stopwatch.stop();
    _stopTicker();

    await _sub?.cancel();
    _sub = null;

    notifyListeners();
  }

  @override
  void dispose() {
    _stopTicker();
    _sub?.cancel();
    super.dispose();
  }
}