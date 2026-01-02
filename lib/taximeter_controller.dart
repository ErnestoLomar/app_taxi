import 'dart:async';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'fare_config.dart';

class _GpsSample {
  final double lat;
  final double lng;
  final double accuracy;
  final double speed; // m/s
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

class _ClosestOnRoute {
  final LatLng point;
  final double distMeters;
  final int segIndex;

  const _ClosestOnRoute(this.point, this.distMeters, this.segIndex);
}

class TaximeterController extends ChangeNotifier {
  final FareConfig config;

  bool running = false;

  Shift shift;
  ServiceChannel channel;

  double distanceMeters = 0;
  final Stopwatch _stopwatch = Stopwatch();

  _GpsSample? _lastAccepted;

  /// Posición para UI (puede ser snappeada si hay ruta)
  Position? currentPosition;

  /// Última posición “filtrada” sin snap (útil para reroute)
  LatLng? _rawLatLng;

  /// Distancia (m) desde la posición filtrada al punto más cercano de la ruta planeada
  double? _distanceToPlannedRouteMeters;

  /// Si el último update aplicó snap a la ruta azul
  bool _snappedLast = false;

  StreamSubscription<Position>? _sub;
  Timer? _ticker;
  Timer? _switchToNormalFilterTimer;

  final List<LatLng> traveledPath = [];

  // ------------------------
  // Filtros / parámetros
  // ------------------------

  static const int _medianWindowSize = 5;
  final List<_GpsSample> _window = [];

  static const double _maxAccuracyMeters = 35.0;

  static const double _maxSpeedMps = 200.0 / 3.6; // 55.55 m/s
  static const double _maxSpeedMargin = 1.15;

  static const double _minMoveBaseMeters = 3.0;
  static const double _absoluteMaxJumpMeters = 0.0;

  // ------------------------
  // UI optimization: thinning
  // ------------------------
  static const double _uiMinSegmentMeters = 6.0; // no dibujar micro-segmentos
  static const int _uiMaxPoints = 2500; // cap opcional para viajes muy largos

  // ------------------------
  // SNAP a ruta (map matching local)
  // ------------------------

  List<LatLng> _plannedRoute = const [];
  int _routeCursor = -1;

  /// Activa/desactiva snapping a la ruta azul
  bool snapToPlannedRoute = true;

  /// Exponer para main
  LatLng? get rawLatLng => _rawLatLng;
  double? get distanceToPlannedRouteMeters => _distanceToPlannedRouteMeters;
  bool get snappedLast => _snappedLast;

  TaximeterController(
      this.config, {
        this.shift = Shift.diurno,
        this.channel = ServiceChannel.calle,
      });

  Duration get elapsed => _stopwatch.elapsed;

  int get units =>
      config.unitsFromTotals(distanceMeters: distanceMeters, elapsed: elapsed);

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

  /// Llama esto desde main.dart cuando calcules/actualices la ruta azul
  void setPlannedRoute(List<LatLng> pts) {
    _plannedRoute = _downsampleRoute(List<LatLng>.from(pts), maxPoints: 800);
    _routeCursor = (_plannedRoute.length >= 2) ? 0 : -1;
    _distanceToPlannedRouteMeters = null;
    _snappedLast = false;
    notifyListeners();
  }

  /// Limpia traza del viaje (línea naranja) y contadores, sin tocar la ruta planeada.
  void resetTripTrace() {
    distanceMeters = 0;
    traveledPath.clear();
    _window.clear();
    _lastAccepted = null;
    _rawLatLng = null;
    _distanceToPlannedRouteMeters = null;
    _snappedLast = false;
    notifyListeners();
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
    // Menor radio = menos “pegado” a calles paralelas y mejor detección de desviación.
    return max(12.0, min(40.0, accuracyMeters * 1.6));
  }

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

  _ClosestOnRoute? _closestPointOnPlannedRoute(LatLng p) {
    if (_plannedRoute.length < 2) return null;

    final latRad = _deg2rad(p.latitude);
    final cosLat = cos(latRad);

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

    for (int i = start; i <= end; i++) {
      final a = _plannedRoute[i];
      final b = _plannedRoute[i + 1];

      final axy = _toXY(a, p, cosLat);
      final bxy = _toXY(b, p, cosLat);

      final vx = bxy.dx - axy.dx;
      final vy = bxy.dy - axy.dy;
      final denom = vx * vx + vy * vy;
      if (denom < 1e-6) continue;

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

    final snapped = _xyToLatLng(bestXY, p, cosLat);
    return _ClosestOnRoute(snapped, bestDist, bestIdx);
  }

  List<LatLng> _downsampleRoute(List<LatLng> pts, {required int maxPoints}) {
    if (pts.length <= maxPoints) return pts;
    final step = (pts.length / maxPoints).ceil();
    final out = <LatLng>[];
    for (int i = 0; i < pts.length; i += step) {
      out.add(pts[i]);
    }
    if (out.isEmpty || out.last != pts.last) out.add(pts.last);
    return out;
  }

  // ------------------------
  // GPS start/stop
  // ------------------------

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
    _lastAccepted = null;
    _rawLatLng = null;
    _distanceToPlannedRouteMeters = null;
    _snappedLast = false;

    _routeCursor = (_plannedRoute.length >= 2) ? 0 : -1;

    _stopwatch
      ..reset()
      ..start();
    _startTicker();

    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) _seedFromPosition(last);
    } catch (_) {}

    await _startLocationStream(distanceFilter: 0);

    _switchToNormalFilterTimer?.cancel();
    _switchToNormalFilterTimer = Timer(const Duration(seconds: 12), () async {
      if (!running) return;
      await _startLocationStream(distanceFilter: 5);
    });

    Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
      timeLimit: const Duration(seconds: 3),
    ).then((pos) {
      if (!running) return;
      _ingestPosition(pos);
    }).catchError((_) {});

    notifyListeners();
  }

  Future<void> _startLocationStream({required int distanceFilter}) async {
    await _sub?.cancel();
    const base = LocationSettings(accuracy: LocationAccuracy.high);

    final settings = LocationSettings(
      accuracy: base.accuracy,
      distanceFilter: distanceFilter,
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
          (pos) => _ingestPosition(pos),
      onError: (_) {},
    );
  }

  void _seedFromPosition(Position pos) {
    final now = pos.timestamp ?? DateTime.now();
    currentPosition = pos;

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

  void _addTraveledPointForUi(LatLng ll) {
    if (traveledPath.isEmpty) {
      traveledPath.add(ll);
      return;
    }

    final last = traveledPath.last;
    final dUi = Geolocator.distanceBetween(
      last.latitude,
      last.longitude,
      ll.latitude,
      ll.longitude,
    );

    if (dUi >= _uiMinSegmentMeters) {
      traveledPath.add(ll);

      // cap opcional (evita listas gigantes)
      if (traveledPath.length > _uiMaxPoints) {
        traveledPath.removeRange(0, traveledPath.length - _uiMaxPoints);
      }
    }
  }

  void _ingestPosition(Position pos) {
    if (!running) return;

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

    _window.add(raw);
    if (_window.length > _medianWindowSize) _window.removeAt(0);
    final filtered = (_window.length >= 3) ? _medianSample(_window) : raw;

    final pFiltered = LatLng(filtered.lat, filtered.lng);
    _rawLatLng = pFiltered;

    final cand = _closestPointOnPlannedRoute(pFiltered);
    _distanceToPlannedRouteMeters = cand?.distMeters;

    final radius = _snapRadiusMeters(filtered.accuracy);
    final bool canSnap = snapToPlannedRoute && cand != null && cand.distMeters <= radius;

    final useLatLng = canSnap ? cand.point : pFiltered;
    _snappedLast = canSnap;
    if (canSnap) _routeCursor = cand.segIndex;

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

    if (last == null) {
      _addTraveledPointForUi(useLatLng);
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

    final minMove = _minMoveThresholdMeters(filtered.accuracy);
    if (d < minMove) {
      return;
    }

    final maxJump = _maxAllowedJumpMeters(dtSafe);
    if (d > maxJump) {
      return;
    }

    distanceMeters += d;

    // UI: agrega menos puntos para que la polyline no se vuelva “pesada”
    _addTraveledPointForUi(useLatLng);

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

    _switchToNormalFilterTimer?.cancel();
    _switchToNormalFilterTimer = null;

    await _sub?.cancel();
    _sub = null;

    notifyListeners();
  }

  @override
  void dispose() {
    _stopTicker();
    _switchToNormalFilterTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}