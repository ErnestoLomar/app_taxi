import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'fare_config.dart';

class TripSample {
  final DateTime time;
  final int elapsedMs;

  final LatLng raw;      // GPS crudo
  final LatLng filtered; // tras mediana
  final LatLng used;     // lo que se usa (snapped o filtered)

  final bool snapped;
  final double? distToRouteMeters;

  final double accuracy;
  final double speed;
  final double heading;

  final bool accepted;
  final String reason; // accepted | seed | min_move | max_jump | bad_accuracy | not_running

  final double? deltaMeters;
  final double? dtSeconds;

  final double cumulativeDistanceMeters;
  final int units;
  final double fare;

  const TripSample({
    required this.time,
    required this.elapsedMs,
    required this.raw,
    required this.filtered,
    required this.used,
    required this.snapped,
    required this.distToRouteMeters,
    required this.accuracy,
    required this.speed,
    required this.heading,
    required this.accepted,
    required this.reason,
    required this.deltaMeters,
    required this.dtSeconds,
    required this.cumulativeDistanceMeters,
    required this.units,
    required this.fare,
  });

  Map<String, dynamic> toJson() => {
    'time_iso': time.toIso8601String(),
    'elapsed_ms': elapsedMs,
    'accepted': accepted,
    'reason': reason,
    'raw': {'lat': raw.latitude, 'lng': raw.longitude},
    'filtered': {'lat': filtered.latitude, 'lng': filtered.longitude},
    'used': {'lat': used.latitude, 'lng': used.longitude},
    'snapped': snapped,
    'dist_to_route_m': distToRouteMeters,
    'accuracy_m': accuracy,
    'speed_mps': speed,
    'heading_deg': heading,
    'delta_m': deltaMeters,
    'dt_s': dtSeconds,
    'cum_distance_m': cumulativeDistanceMeters,
    'units': units,
    'fare': fare,
  };
}

class TaximeterController extends ChangeNotifier {
  final FareConfig config;

  Shift shift;
  ServiceChannel channel;

  bool running = false;

  final Stopwatch _stopwatch = Stopwatch();
  Timer? _ticker;

  double distanceMeters = 0.0;

  final List<LatLng> traveledPath = [];

  Position? currentPosition;

  LatLng? _rawLatLng;
  LatLng? get rawLatLng => _rawLatLng;

  double? _distanceToPlannedRouteMeters;
  double? get distanceToPlannedRouteMeters => _distanceToPlannedRouteMeters;

  bool _snappedLast = false;
  bool get snappedLast => _snappedLast;

  DateTime? tripStartedAt;
  DateTime? tripEndedAt;

  // ------------------------
  // Logging (para export)
  // ------------------------
  bool logGpsSamples = true;
  static const int _maxLoggedSamples = 20000;
  final List<TripSample> _samples = [];
  UnmodifiableListView<TripSample> get samples => UnmodifiableListView(_samples);

  void _pushSample(TripSample s) {
    if (!logGpsSamples) return;
    _samples.add(s);
    if (_samples.length > _maxLoggedSamples) {
      final overflow = _samples.length - _maxLoggedSamples;
      _samples.removeRange(0, overflow);
    }
  }

  // ------------------------
  // GPS smoothing / filtros
  // ------------------------

  static const int _windowSize = 5;
  final List<_GpsSample> _window = [];

  static const double _maxAccuracyMeters = 35.0;

  static const double _maxSpeedMps = 200.0 / 3.6;
  static const double _maxSpeedMargin = 1.15;

  static const double _minMoveBaseMeters = 3.0;

  static const double _absoluteMaxJumpMeters = 0.0;

  _GpsSample? _lastAccepted;

  // ------------------------
  // SNAP a ruta (map matching local)
  // ------------------------

  List<LatLng> _plannedRoute = const [];
  int _routeCursor = -1;

  bool snapToPlannedRoute = true;

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

    _samples.clear();
    tripStartedAt = null;
    tripEndedAt = null;

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
    final v = List<double>.from(values)..sort();
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

  // ------------------------
  // Start / Stop
  // ------------------------

  StreamSubscription<Position>? _sub;

  Future<bool> start() async {
    if (running) return false;

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return false;

    running = true;
    tripEndedAt = null;

    _stopwatch.reset();
    _stopwatch.start();
    tripStartedAt = DateTime.now();

    _startTicker();

    final settings = const LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
    );

    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(
          (pos) => _ingestPosition(pos),
      onError: (_) {},
    );

    notifyListeners();
    return true;
  }

  void stop() {
    if (!running) return;

    running = false;
    _sub?.cancel();
    _sub = null;

    _stopwatch.stop();
    _stopTicker();

    tripEndedAt = DateTime.now();

    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  // ------------------------
  // Core ingest
  // ------------------------

  void _ingestPosition(Position pos) {
    final now = pos.timestamp ?? DateTime.now();
    final elapsedMs = _stopwatch.elapsedMilliseconds;

    if (!running) {
      // (opcional) loggear aunque no esté corriendo
      return;
    }

    final acc = (pos.accuracy.isFinite ? pos.accuracy : 9999.0);
    final speed = (pos.speed.isFinite ? pos.speed : 0.0);
    final heading = (pos.heading.isFinite ? pos.heading : 0.0);

    final raw = LatLng(pos.latitude, pos.longitude);
    _rawLatLng = raw;
    currentPosition = pos;

    // Accuracy filter
    if (acc > _maxAccuracyMeters) {
      _pushSample(
        TripSample(
          time: now,
          elapsedMs: elapsedMs,
          raw: raw,
          filtered: raw,
          used: raw,
          snapped: false,
          distToRouteMeters: _distanceToPlannedRouteMeters,
          accuracy: acc,
          speed: speed,
          heading: heading,
          accepted: false,
          reason: 'bad_accuracy',
          deltaMeters: null,
          dtSeconds: null,
          cumulativeDistanceMeters: distanceMeters,
          units: units,
          fare: fare,
        ),
      );
      notifyListeners();
      return;
    }

    // Mediana window
    _window.add(_GpsSample(
      lat: raw.latitude,
      lng: raw.longitude,
      accuracy: acc,
      speed: speed,
      heading: heading,
      time: now,
    ));
    if (_window.length > _windowSize) _window.removeAt(0);

    final med = _medianSample(_window);
    final filtered = LatLng(med.lat, med.lng);

    // Snap (si hay ruta)
    final used = _maybeSnap(filtered, now);

    // Cálculo de distancia incremental
    final last = _lastAccepted;
    if (last == null) {
      _lastAccepted = _GpsSample(
        lat: used.latitude,
        lng: used.longitude,
        accuracy: med.accuracy,
        speed: med.speed,
        heading: med.heading,
        time: now,
      );

      traveledPath.add(used);

      _pushSample(
        TripSample(
          time: now,
          elapsedMs: elapsedMs,
          raw: raw,
          filtered: filtered,
          used: used,
          snapped: _snappedLast,
          distToRouteMeters: _distanceToPlannedRouteMeters,
          accuracy: med.accuracy,
          speed: med.speed,
          heading: med.heading,
          accepted: true,
          reason: 'seed',
          deltaMeters: 0,
          dtSeconds: 0,
          cumulativeDistanceMeters: distanceMeters,
          units: units,
          fare: fare,
        ),
      );

      notifyListeners();
      return;
    }

    final dt = max(0.001, now.difference(last.time).inMilliseconds / 1000.0);

    final d = Geolocator.distanceBetween(
      last.lat,
      last.lng,
      used.latitude,
      used.longitude,
    );

    // min move (dinámico por speed/accuracy)
    final minMove = max(_minMoveBaseMeters, med.accuracy * 0.20);
    if (d < minMove) {
      _pushSample(
        TripSample(
          time: now,
          elapsedMs: elapsedMs,
          raw: raw,
          filtered: filtered,
          used: used,
          snapped: _snappedLast,
          distToRouteMeters: _distanceToPlannedRouteMeters,
          accuracy: med.accuracy,
          speed: med.speed,
          heading: med.heading,
          accepted: false,
          reason: 'min_move',
          deltaMeters: d,
          dtSeconds: dt,
          cumulativeDistanceMeters: distanceMeters,
          units: units,
          fare: fare,
        ),
      );
      notifyListeners();
      return;
    }

    // max jump (por velocidad)
    final maxBySpeed = (_maxSpeedMps * _maxSpeedMargin) * dt;
    final maxJump = (_absoluteMaxJumpMeters > 0) ? min(maxBySpeed, _absoluteMaxJumpMeters) : maxBySpeed;

    if (d > maxJump && d > 25) {
      _pushSample(
        TripSample(
          time: now,
          elapsedMs: elapsedMs,
          raw: raw,
          filtered: filtered,
          used: used,
          snapped: _snappedLast,
          distToRouteMeters: _distanceToPlannedRouteMeters,
          accuracy: med.accuracy,
          speed: med.speed,
          heading: med.heading,
          accepted: false,
          reason: 'max_jump',
          deltaMeters: d,
          dtSeconds: dt,
          cumulativeDistanceMeters: distanceMeters,
          units: units,
          fare: fare,
        ),
      );
      notifyListeners();
      return;
    }

    // Accept
    distanceMeters += d;

    _lastAccepted = _GpsSample(
      lat: used.latitude,
      lng: used.longitude,
      accuracy: med.accuracy,
      speed: med.speed,
      heading: med.heading,
      time: now,
    );

    traveledPath.add(used);

    _pushSample(
      TripSample(
        time: now,
        elapsedMs: elapsedMs,
        raw: raw,
        filtered: filtered,
        used: used,
        snapped: _snappedLast,
        distToRouteMeters: _distanceToPlannedRouteMeters,
        accuracy: med.accuracy,
        speed: med.speed,
        heading: med.heading,
        accepted: true,
        reason: 'accepted',
        deltaMeters: d,
        dtSeconds: dt,
        cumulativeDistanceMeters: distanceMeters,
        units: units,
        fare: fare,
      ),
    );

    notifyListeners();
  }

  // ------------------------
  // Snap helpers
  // ------------------------

  LatLng _maybeSnap(LatLng p, DateTime now) {
    if (!snapToPlannedRoute || _plannedRoute.length < 2) {
      _distanceToPlannedRouteMeters = null;
      _snappedLast = false;
      return p;
    }

    final snapped = _snapToPlannedRoute(p);
    return snapped;
  }

  LatLng _snapToPlannedRoute(LatLng p) {
    // Equirectangular projection para ciudad
    const double R = 6371000.0;
    final double lat0 = p.latitude * (pi / 180.0);
    final double cosLat = cos(lat0);

    Offset _toXY(LatLng ll) {
      final x = (ll.longitude * (pi / 180.0)) * R * cosLat;
      final y = (ll.latitude * (pi / 180.0)) * R;
      return Offset(x, y);
    }

    LatLng _xyToLatLng(Offset xy) {
      final lat = (xy.dy / R) * (180.0 / pi);
      final lng = (xy.dx / (R * cosLat)) * (180.0 / pi);
      return LatLng(lat, lng);
    }

    final pxy = _toXY(p);

    // Ventana de búsqueda (evita saltos lejanos)
    final int n = _plannedRoute.length;
    int start = 0;
    int end = n - 2;

    if (_routeCursor >= 0) {
      start = max(0, _routeCursor - 30);
      end = min(n - 2, _routeCursor + 80);
    }

    double bestDist = double.infinity;
    Offset bestXY = Offset.zero;
    int bestSeg = _routeCursor >= 0 ? _routeCursor : 0;

    for (int i = start; i <= end; i++) {
      final a = _plannedRoute[i];
      final b = _plannedRoute[i + 1];

      final ax = _toXY(a);
      final bx = _toXY(b);

      final ab = bx - ax;
      final ap = pxy - ax;

      final abLen2 = ab.dx * ab.dx + ab.dy * ab.dy;
      if (abLen2 == 0) continue;

      double t = (ap.dx * ab.dx + ap.dy * ab.dy) / abLen2;
      if (t < 0) t = 0;
      if (t > 1) t = 1;

      final cx = ax.dx + ab.dx * t;
      final cy = ax.dy + ab.dy * t;

      final dx = pxy.dx - cx;
      final dy = pxy.dy - cy;

      final d = sqrt(dx * dx + dy * dy);
      if (d < bestDist) {
        bestDist = d;
        bestXY = Offset(cx, cy);
        bestSeg = i;
      }
    }

    _routeCursor = bestSeg;
    _distanceToPlannedRouteMeters = bestDist;

    // decide si realmente “snap”
    // umbral dinámico: si accuracy es grande, no forzar snap tan agresivo
    final lastAcc = (_window.isNotEmpty ? _window.last.accuracy : 25.0);
    final threshold = max(18.0, lastAcc * 2.2);

    if (bestDist <= threshold) {
      _snappedLast = true;
      return _xyToLatLng(bestXY);
    } else {
      _snappedLast = false;
      return p;
    }
  }

  List<LatLng> _downsampleRoute(List<LatLng> pts, {required int maxPoints}) {
    if (pts.length <= maxPoints) return pts;
    if (maxPoints < 2) return [pts.first, pts.last];

    final out = <LatLng>[];
    final step = (pts.length - 1) / (maxPoints - 1);

    for (int i = 0; i < maxPoints; i++) {
      final idx = (i * step).round().clamp(0, pts.length - 1);
      out.add(pts[idx]);
    }
    return out;
  }

  // ------------------------
  // Export JSON builder
  // ------------------------

  Map<String, dynamic> buildTripExport({
    LatLng? origin,
    LatLng? destination,
    String? originLabel,
    String? destinationLabel,
    List<LatLng>? plannedRoute,
  }) {
    List<Map<String, double>> packLine(List<LatLng> pts, {int? max}) {
      if (max != null && pts.length > max) {
        final down = _downsampleRoute(List<LatLng>.from(pts), maxPoints: max);
        return down.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
      }
      return pts.map((p) => {'lat': p.latitude, 'lng': p.longitude}).toList();
    }

    return {
      'exported_at': DateTime.now().toIso8601String(),
      'shift': shift.name,
      'channel': channel.name,
      'trip': {
        'started_at': tripStartedAt?.toIso8601String(),
        'ended_at': tripEndedAt?.toIso8601String(),
        'elapsed_ms': elapsed.inMilliseconds,
        'distance_m': distanceMeters,
        'units': units,
        'fare': fare,
      },
      'origin': origin == null
          ? null
          : {
        'lat': origin.latitude,
        'lng': origin.longitude,
        'label': originLabel ?? '',
      },
      'destination': destination == null
          ? null
          : {
        'lat': destination.latitude,
        'lng': destination.longitude,
        'label': destinationLabel ?? '',
      },
      'planned_route': plannedRoute == null ? null : packLine(plannedRoute, max: 1500),
      'traveled_path': packLine(traveledPath),
      'samples': _samples.map((s) => s.toJson()).toList(),
    };
  }
}

class _GpsSample {
  final double lat;
  final double lng;
  final double accuracy;
  final double speed;
  final double heading;
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