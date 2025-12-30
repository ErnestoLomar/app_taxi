import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset; // <-- AGREGA ESTO
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

class _SnapResult {
  final LatLng point;
  final double distMeters;
  final int segIndex; // índice del segmento [i -> i+1] donde cayó el snap

  const _SnapResult(this.point, this.distMeters, this.segIndex);
}

class TaximeterController extends ChangeNotifier {
  final FareConfig config;

  bool running = false;

  Shift shift;
  ServiceChannel channel;

  double distanceMeters = 0;
  final Stopwatch _stopwatch = Stopwatch();

  _GpsSample? _lastAccepted;

  // Posición actual (filtrada / o snappeada) para UI (tracking cámara / marcador)
  Position? currentPosition;

  StreamSubscription<Position>? _sub;
  final List<LatLng> traveledPath = [];

  Timer? _ticker;

  // ------------------------
  // Filtros / parámetros
  // ------------------------

  static const int _medianWindowSize = 5;
  final List<_GpsSample> _window = [];

  static const double _maxAccuracyMeters = 35.0;

  static const double _maxSpeedMps = 200.0 / 3.6;
  static const double _maxSpeedMargin = 1.15;

  static const double _minMoveBaseMeters = 3.0;

  static const double _absoluteMaxJumpMeters = 0.0;

  // ------------------------
  // SNAP a ruta (map matching local)
  // ------------------------

  List<LatLng> _plannedRoute = const [];
  int _routeCursor = -1; // ayuda a no “saltar” a segmentos lejanos

  /// Activa/desactiva snapping a la ruta azul
  bool snapToPlannedRoute = true;

  /// Llama esto desde main.dart cuando calcules la ruta
  void setPlannedRoute(List<LatLng> pts) {
    _plannedRoute = List<LatLng>.from(pts);
    _routeCursor = (_plannedRoute.length >= 2) ? 0 : -1;
    notifyListeners();
  }

  /// Limpia SOLO el trazo del viaje (línea naranja) y contadores,
  /// para poder iniciar otro viaje sin que se quede dibujado el anterior.
  /// No detiene/inicia GPS (eso lo hace start/stop).
  void resetTripTrace() {
    distanceMeters = 0;
    traveledPath.clear();
    _window.clear();
    _lastAccepted = null;
    notifyListeners();
  }


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
  // Mediana
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
      time: samples.map((s) => s.time).reduce((a, b) => a.isAfter(b) ? a : b),
    );
  }

  double _minMoveThresholdMeters(double accuracyMeters) {
    final dyn = accuracyMeters * 0.6;
    return max(_minMoveBaseMeters, min(20.0, dyn));
  }

  double _maxAllowedJumpMeters(Duration dt) {
    final seconds = max(1.0, dt.inMilliseconds / 1000.0);
    var maxDist = _maxSpeedMps * seconds * _maxSpeedMargin;
    if (_absoluteMaxJumpMeters > 0) maxDist = min(maxDist, _absoluteMaxJumpMeters);
    return maxDist;
  }

  // ------------------------
  // SNAP helpers
  // ------------------------

  double _snapRadiusMeters(double accuracyMeters) {
    // Si el GPS está a 10m de accuracy, tolera ~20m para “pegarlo” a la ruta
    // (esto elimina el offset lateral típico).
    return max(15.0, min(55.0, accuracyMeters * 2.0));
  }

  // Convierte un LatLng a (x,y) en metros relativo al punto p (origen).
  // Aproximación equirectangular (suficiente para distancias pequeñas).
  static const double _R = 6371000.0;
  double _deg2rad(double d) => d * pi / 180.0;
  double _rad2deg(double r) => r * 180.0 / pi;

  Offset _toXY(LatLng ll, LatLng p, double cosLat) {
    final dLat = _deg2rad(ll.latitude - p.latitude);
    final dLon = _deg2rad(ll.longitude - p.longitude);
    final x = dLon * _R * cosLat;
    final y = dLat * _R;
    return Offset(x, y);
  }

  LatLng _xyToLatLng(Offset xy, LatLng p, double cosLat) {
    final dLat = xy.dy / _R;
    final dLon = (cosLat.abs() < 1e-8) ? 0.0 : (xy.dx / (_R * cosLat));
    return LatLng(
      p.latitude + _rad2deg(dLat),
      p.longitude + _rad2deg(dLon),
    );
  }

  _SnapResult? _snapToPlannedRoute(LatLng p, double radiusMeters) {
    if (!snapToPlannedRoute) return null;
    if (_plannedRoute.length < 2) return null;

    final latRad = _deg2rad(p.latitude);
    final cosLat = cos(latRad);

    // Limita búsqueda alrededor del cursor para evitar “pegarse” a calles paralelas lejanas.
    final n = _plannedRoute.length;
    int start = 0;
    int end = n - 2;
    if (_routeCursor >= 0) {
      start = max(0, _routeCursor - 30);
      end = min(n - 2, _routeCursor + 80);
    }

    double bestDist = double.infinity;
    Offset bestXY = Offset.zero;
    int bestIdx = start;

    // p es el origen (0,0)
    for (int i = start; i <= end; i++) {
      final a = _plannedRoute[i];
      final b = _plannedRoute[i + 1];

      final axy = _toXY(a, p, cosLat);
      final bxy = _toXY(b, p, cosLat);

      final vx = bxy.dx - axy.dx;
      final vy = bxy.dy - axy.dy;
      final denom = vx * vx + vy * vy;
      if (denom < 1e-6) continue;

      // punto más cercano del segmento al origen
      final t = (-axy.dx * vx - axy.dy * vy) / denom;
      final tc = t.clamp(0.0, 1.0);

      final cx = axy.dx + tc * vx;
      final cy = axy.dy + tc * vy;

      final dist = sqrt(cx * cx + cy * cy);
      if (dist < bestDist) {
        bestDist = dist;
        bestXY = Offset(cx, cy);
        bestIdx = i;
      }
    }

    if (bestDist > radiusMeters) return null;

    final snapped = _xyToLatLng(bestXY, p, cosLat);
    return _SnapResult(snapped, bestDist, bestIdx);
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

    // 1) Arranca inmediatamente
    running = true;
    distanceMeters = 0;
    traveledPath.clear();
    _window.clear();

    // reinicia cursor si hay ruta planeada
    _routeCursor = (_plannedRoute.length >= 2) ? 0 : -1;

    _lastAccepted = null;

    _stopwatch
      ..reset()
      ..start();
    _startTicker();

    // 2) Semilla rápida: última ubicación conocida (si existe)
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _seedFromPosition(last);
      }
    } catch (_) {}

    // 3) Empieza a escuchar el stream YA (esto suele llegar más rápido que getCurrentPosition)
    // distanceFilter 0 acelera el primer evento (luego puedes subirlo a 5 si quieres)
    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
          (pos) => _ingestPosition(pos),
      onError: (_) {},
    );

    // 4) Fuerza un fix fresco con timeout corto (no bloquea el inicio)
    Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 3),
    ).then((pos) {
      if (!running) return;
      _ingestPosition(pos);
    }).catchError((_) {});

    notifyListeners();
  }

  /// Usa lastKnown para que el UI ya tenga "algo" y la cámara/marker no se queden en cero.
  /// No suma distancia aquí.
  void _seedFromPosition(Position pos) {
    final now = pos.timestamp ?? DateTime.now();

    // actualiza currentPosition para UI
    currentPosition = pos;

    // si es razonable, inicia traveledPath con ese punto para que haya una referencia visual
    final double acc = (pos.accuracy.isFinite ? pos.accuracy : 999.0);
    if (acc <= (_maxAccuracyMeters * 2)) {
      traveledPath.add(LatLng(pos.latitude, pos.longitude));
      _lastAccepted = _GpsSample(
        lat: pos.latitude,
        lng: pos.longitude,
        accuracy: acc,
        speed: pos.speed.isFinite ? pos.speed : 0.0,
        heading: pos.heading.isFinite ? pos.heading : 0.0,
        time: now,
      );
    }

    notifyListeners();
  }

  /// Procesa una lectura GPS aplicando: accuracy -> mediana -> snap -> minMove -> maxSpeed
  void _ingestPosition(Position pos) {
    if (!running) return;

    // 1) accuracy
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

    // 2) mediana
    _window.add(raw);
    if (_window.length > _medianWindowSize) _window.removeAt(0);
    final filtered = (_window.length >= 3) ? _medianSample(_window) : raw;

    // 2.5) snap a ruta planeada
    final pFiltered = LatLng(filtered.lat, filtered.lng);
    final snapRadius = _snapRadiusMeters(filtered.accuracy);
    final snap = _snapToPlannedRoute(pFiltered, snapRadius);

    final useLatLng = snap?.point ?? pFiltered;
    if (snap != null) _routeCursor = snap.segIndex;

    // UI: posición para cámara/marker
    currentPosition = Position(
      latitude: useLatLng.latitude,
      longitude: useLatLng.longitude,
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

    // Si todavía no hay punto aceptado (inicio rápido), acepta este como base sin sumar distancia
    if (last == null) {
      traveledPath.add(useLatLng);
      _lastAccepted = _GpsSample(
        lat: useLatLng.latitude,
        lng: useLatLng.longitude,
        accuracy: filtered.accuracy,
        speed: filtered.speed,
        heading: filtered.heading,
        time: filtered.time,
      );
      notifyListeners();
      return;
    }

    final dt = filtered.time.difference(last.time);
    final dtSafe = dt.isNegative ? const Duration(seconds: 1) : dt;

    final d = Geolocator.distanceBetween(
      last.lat,
      last.lng,
      useLatLng.latitude,
      useLatLng.longitude,
    );

    // 3) minMove (ruido)
    final minMove = _minMoveThresholdMeters(filtered.accuracy);
    if (d < minMove) {
      notifyListeners();
      return;
    }

    // 4) maxSpeed (200 km/h)
    final maxJump = _maxAllowedJumpMeters(dtSafe);
    if (d > maxJump) {
      notifyListeners();
      return;
    }

    // 5) aceptar
    distanceMeters += d;
    traveledPath.add(useLatLng);

    _lastAccepted = _GpsSample(
      lat: useLatLng.latitude,
      lng: useLatLng.longitude,
      accuracy: filtered.accuracy,
      speed: filtered.speed,
      heading: filtered.heading,
      time: filtered.time,
    );

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