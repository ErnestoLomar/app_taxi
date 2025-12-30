import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

import 'app_theme.dart';
import 'fare_config.dart';
import 'taximeter_controller.dart';
import 'directions_service.dart';
import 'places_service.dart';
import 'place_autocomplete_field.dart';
import 'route_info.dart';

late final String kGoogleWebKey;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');

  kGoogleWebKey = (dotenv.env['GOOGLE_WEB_KEY'] ?? '').trim();

  if (kGoogleWebKey.isEmpty) {
    runApp(const _MissingEnvApp());
    return;
  }

  runApp(const TaxiApp());
}

class _MissingEnvApp extends StatelessWidget {
  const _MissingEnvApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Center(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Falta GOOGLE_WEB_KEY en .env\n\n'
                        '1) Crea .env en la raíz\n'
                        '2) Agrega GOOGLE_WEB_KEY=TU_KEY\n'
                        '3) Declara .env en assets del pubspec.yaml\n',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 15, height: 1.35),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class TaxiApp extends StatelessWidget {
  const TaxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Taxi SCT',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const TaxiMapTaximeterPage(),
    );
  }
}

enum RidePhase { idle, routeReady, inTrip, finished }

class TaxiMapTaximeterPage extends StatefulWidget {
  const TaxiMapTaximeterPage({super.key});

  @override
  State<TaxiMapTaximeterPage> createState() => _TaxiMapTaximeterPageState();
}

class _TaxiMapTaximeterPageState extends State<TaxiMapTaximeterPage> {
  GoogleMapController? _map;

  // -------------------------
  // Rerouting (recalcular ruta)
  // -------------------------
  bool _rerouting = false;
  DateTime _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);

  DateTime? _offRouteSince;
  int _offRouteHits = 0;

  Timer? _rerouteTimer;
  double _distanceAtLastReroute = 0;

  // Ajustes para bajar costo (Directions):
  static const Duration _rerouteCheckEvery = Duration(seconds: 4);
  static const int _hitsNeeded = 3; // 3 checks * 4s = ~12s persistente
  static const int _cooldownSeconds = 180; // 3 min mínimo entre reroutes
  static const double _baseThresholdMeters = 70.0;
  static const double _minSpeedForRerouteMps = 1.5; // ~5.4 km/h
  static const double _minDistanceSinceLastReroute = 80.0; // evita cascadas
  static const double _skipRerouteIfNearDestMeters = 220.0;

  bool _followCar = true;
  bool _isProgrammaticMove = false;
  DateTime _lastFollowMove = DateTime.fromMillisecondsSinceEpoch(0);
  LatLng? _lastFollowTarget;

  LatLng _initialCenter = const LatLng(22.1565, -100.9855);
  LatLng? _origin;
  LatLng? _destination;

  RouteInfo? _route;
  String _status = 'Escribe ORIGEN y DESTINO o toca el mapa';

  RidePhase _phase = RidePhase.idle;

  late final FareConfig _cfg;
  late final TaximeterController _taximeter;
  late final DirectionsService _directions;
  late final PlacesService _places;

  final _originCtl = TextEditingController();
  final _destCtl = TextEditingController();

  bool _locating = false;
  bool _loadingRoute = false;
  bool _startingTrip = false;

  static const LatLng _slpCenter = LatLng(22.1565, -100.9855);

  @override
  void initState() {
    super.initState();

    _cfg = const FareConfig(
      baseDiurnoCalle: 16.20,
      baseNocturnoCalle: 21.00,
      baseDiurnoTelefonico: 21.00,
      baseNocturnoTelefonico: 25.90,
      baseDiurnoApp: 21.00,
      baseNocturnoApp: 25.90,
      stepCost: 1.825,
      stepSeconds: 39,
      stepMeters: 250,
      roundingStep: 0.01,
    );

    _taximeter = TaximeterController(_cfg)
      ..addListener(() {
        _maybeFollowCar();
        if (mounted) setState(() {});
      });

    _taximeter.setPlannedRoute(const []);

    _directions = DirectionsService(kGoogleWebKey);

    _places = PlacesService(
      kGoogleWebKey,
      restrictToSlp: true,
    );

    // Reroute con timer (no en cada update) => menos CPU y menos riesgo de llamar Directions de más
    _rerouteTimer = Timer.periodic(_rerouteCheckEvery, (_) {
      _maybeRerouteIfOffRoute();
    });

    _centerOnUserOnce();
  }

  @override
  void dispose() {
    _rerouteTimer?.cancel();
    _originCtl.dispose();
    _destCtl.dispose();
    _taximeter.dispose();
    super.dispose();
  }

  bool get _locked =>
      _taximeter.running || _phase == RidePhase.inTrip || _startingTrip;

  Future<void> _centerOnUserOnce() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;

      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      _initialCenter = LatLng(pos.latitude, pos.longitude);
      await _map?.animateCamera(CameraUpdate.newLatLngZoom(_initialCenter, 15));
      if (mounted) setState(() {});
    } catch (_) {}
  }

  double _safeHeading(Position p) {
    final h = p.heading;
    if (!h.isFinite) return 0.0;
    if (h < 0) return 0.0;
    return h;
  }

  Future<void> _animateFollowCamera(LatLng target, double bearing) async {
    if (_map == null) return;

    _isProgrammaticMove = true;
    try {
      await _map!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: target,
            zoom: 18,
            tilt: 55,
            bearing: bearing,
          ),
        ),
      );
    } finally {
      Future.delayed(const Duration(milliseconds: 600), () {
        _isProgrammaticMove = false;
      });
    }
  }

  void _maybeFollowCar({bool force = false}) {
    if (!_followCar) return;
    if (!_taximeter.running) return;
    if (_map == null) return;

    final pos = _taximeter.currentPosition;
    if (pos == null) return;

    final now = DateTime.now();

    if (!force && now.difference(_lastFollowMove).inMilliseconds < 900) return;

    final target = LatLng(pos.latitude, pos.longitude);

    if (!force && _lastFollowTarget != null) {
      final d = Geolocator.distanceBetween(
        _lastFollowTarget!.latitude,
        _lastFollowTarget!.longitude,
        target.latitude,
        target.longitude,
      );
      if (d < 8) return;
    }

    _lastFollowMove = now;
    _lastFollowTarget = target;

    _animateFollowCamera(target, _safeHeading(pos));
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _goToMyLocation() async {
    if (_locating) return;
    setState(() => _locating = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _status = 'Activa el GPS para ubicarte.');
        _snack('Activa el GPS para ubicarte.');
        return;
      }

      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        setState(() => _status = 'Permiso de ubicación no concedido.');
        _snack('Permiso de ubicación no concedido.');
        return;
      }

      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        final ll = LatLng(last.latitude, last.longitude);
        await _map?.animateCamera(
          CameraUpdate.newCameraPosition(CameraPosition(target: ll, zoom: 17)),
        );
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 6),
      );

      final me = LatLng(pos.latitude, pos.longitude);
      await _map?.animateCamera(
        CameraUpdate.newCameraPosition(CameraPosition(target: me, zoom: 17)),
      );
    } on TimeoutException {
      setState(() => _status = 'Ubicación tardó; usando última conocida.');
      _snack('Ubicación tardó; usando última conocida.');
    } catch (e) {
      setState(() => _status = 'Error obteniendo ubicación: $e');
      _snack('Error obteniendo ubicación');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _resetRouteState() {
    _route = null;
    _taximeter.setPlannedRoute(const []);
    if (_phase != RidePhase.inTrip) _phase = RidePhase.idle;
  }

  void _onMapTap(LatLng p) {
    if (_locked) return;

    setState(() {
      if (_origin == null) {
        _origin = p;
        _originCtl.text = 'Punto seleccionado';
        _status = 'Origen listo. Selecciona DESTINO';
      } else if (_destination == null) {
        _destination = p;
        _destCtl.text = 'Punto seleccionado';
        _status = 'Destino listo. Pulsa "Calcular ruta"';
      } else {
        _destination = p;
        _destCtl.text = 'Punto seleccionado';
        _status = 'Destino actualizado. Pulsa "Calcular ruta"';
      }
      _resetRouteState();
    });
  }

  Future<void> _setOriginFromPlace(String desc, String placeId, String token) async {
    if (_locked) return;
    final ll = await _places.placeIdToLatLng(placeId, sessionToken: token, requireSlp: true);
    if (ll == null) {
      setState(() => _status = 'No se pudo obtener coordenadas del origen');
      return;
    }
    setState(() {
      _origin = ll;
      _status = 'Origen listo. Selecciona destino';
      _resetRouteState();
    });
    await _map?.animateCamera(CameraUpdate.newLatLngZoom(ll, 15));
  }

  Future<void> _setDestFromPlace(String desc, String placeId, String token) async {
    if (_locked) return;
    final ll = await _places.placeIdToLatLng(placeId, sessionToken: token, requireSlp: true);
    if (ll == null) {
      setState(() => _status = 'No se pudo obtener coordenadas del destino');
      return;
    }
    setState(() {
      _destination = ll;
      _status = 'Destino listo. Pulsa "Calcular ruta"';
      _resetRouteState();
    });
    await _map?.animateCamera(CameraUpdate.newLatLngZoom(ll, 15));
  }

  Future<void> _calculateRoute() async {
    if (_origin == null || _destination == null || _locked) return;

    setState(() {
      _loadingRoute = true;
      _status = 'Calculando ruta...';
    });

    try {
      final r = await _directions.fetchRoute(origin: _origin!, destination: _destination!);

      if (r.polyline.isNotEmpty) {
        _taximeter.setPlannedRoute(r.polyline);
      } else {
        _taximeter.setPlannedRoute(const []);
      }

      setState(() {
        _route = r;
        if (r.polyline.isEmpty) {
          _phase = RidePhase.idle;
          _status = 'Sin ruta (ZERO_RESULTS).';
        } else {
          _phase = RidePhase.routeReady;
          _status = 'Ruta lista. Revisa resumen y presiona "Iniciar viaje".';
        }
      });

      if (r.polyline.isNotEmpty) await _fitBounds(r.polyline);
    } catch (e) {
      _taximeter.setPlannedRoute(const []);
      setState(() {
        _status = 'Error calculando ruta: $e';
        _phase = RidePhase.idle;
      });
    } finally {
      if (mounted) setState(() => _loadingRoute = false);
    }
  }

  Future<void> _fitBounds(List<LatLng> points) async {
    if (_map == null || points.isEmpty) return;

    double minLat = points.first.latitude, maxLat = points.first.latitude;
    double minLng = points.first.longitude, maxLng = points.first.longitude;

    for (final p in points) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    await _map!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 70));
  }

  double? _estimatedFare() {
    final r = _route;
    if (r == null || r.distanceMeters <= 0 || r.durationSeconds <= 0) return null;

    return _cfg.fareFromTotals(
      shift: _taximeter.shift,
      channel: _taximeter.channel,
      distanceMeters: r.distanceMeters.toDouble(),
      elapsed: Duration(seconds: r.durationSeconds),
    );
  }

  Future<void> _startTrip() async {
    if (_route == null || _route!.polyline.isEmpty) return;
    if (_taximeter.running || _startingTrip) return;

    setState(() {
      _startingTrip = true;
      _status = 'Iniciando viaje...';
    });

    _taximeter.resetTripTrace();
    _taximeter.setPlannedRoute(_route!.polyline);

    // reset detector reroute
    _offRouteSince = null;
    _offRouteHits = 0;
    _distanceAtLastReroute = 0;
    _lastRerouteAt = DateTime.fromMillisecondsSinceEpoch(0);

    try {
      await _taximeter.start();

      if (!mounted) return;
      setState(() {
        _phase = RidePhase.inTrip;
        _status = 'Viaje en curso (taxímetro SCT activo)';
        _followCar = true;
      });
      _maybeFollowCar(force: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
      _snack('Error iniciando viaje');
    } finally {
      if (mounted) setState(() => _startingTrip = false);
    }
  }

  Future<void> _stopTrip() async {
    if (!_taximeter.running) return;
    await _taximeter.stop();
    if (!mounted) return;
    setState(() {
      _phase = RidePhase.finished;
      _status = 'Viaje finalizado';
    });
  }

  void _clearAll() {
    if (_taximeter.running || _startingTrip) return;

    _taximeter.setPlannedRoute(const []);
    _taximeter.resetTripTrace();

    setState(() {
      _origin = null;
      _destination = null;
      _route = null;
      _originCtl.clear();
      _destCtl.clear();
      _phase = RidePhase.idle;
      _status = 'Escribe ORIGEN y DESTINO o toca el mapa';
    });
  }

  // -------------------------
  // Reroute “barato” (menos Directions)
  // -------------------------
  Future<void> _maybeRerouteIfOffRoute() async {
    if (!_taximeter.running) return;
    if (_destination == null) return;
    if (_route == null || _route!.polyline.length < 2) return;
    if (_rerouting) return;

    final pos = _taximeter.currentPosition;
    if (pos == null) return;

    // Evita reroute si vas casi detenido (reduce falsos positivos y costo)
    if (pos.speed.isFinite && pos.speed < _minSpeedForRerouteMps) {
      _offRouteSince = null;
      _offRouteHits = 0;
      return;
    }

    // Si ya estás muy cerca del destino, no reroute
    final distToDest = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      _destination!.latitude,
      _destination!.longitude,
    );
    if (distToDest < _skipRerouteIfNearDestMeters) {
      _offRouteSince = null;
      _offRouteHits = 0;
      return;
    }

    // Evita cascadas: exige un mínimo de avance desde el último reroute
    if ((_taximeter.distanceMeters - _distanceAtLastReroute) < _minDistanceSinceLastReroute) {
      return;
    }

    // Usa distancia a ruta ya computada en el controller (casi “gratis” CPU)
    final distToRoute = _taximeter.distanceToPlannedRouteMeters;
    if (distToRoute == null) return;

    final now = DateTime.now();

    // Umbral dinámico: base + depende de accuracy
    final acc = (pos.accuracy.isFinite ? pos.accuracy : 25.0);
    final threshold = max(_baseThresholdMeters, acc * 2.6);

    // Cooldown fuerte
    final cooldownOk = now.difference(_lastRerouteAt).inSeconds >= _cooldownSeconds;
    if (!cooldownOk) return;

    if (distToRoute > threshold) {
      _offRouteSince ??= now;
      _offRouteHits++;

      if (_offRouteHits >= _hitsNeeded) {
        final from = _taximeter.rawLatLng ?? LatLng(pos.latitude, pos.longitude);
        await _doReroute(from: from);
      }
    } else {
      _offRouteSince = null;
      _offRouteHits = 0;
    }
  }

  Future<void> _doReroute({required LatLng from}) async {
    if (_destination == null) return;

    _rerouting = true;
    setState(() => _status = 'Recalculando ruta...');

    try {
      final r = await _directions.fetchRoute(
        origin: from,
        destination: _destination!,
      );

      if (r.polyline.length >= 2) {
        setState(() {
          _route = r;
          _status = 'Ruta actualizada';
        });

        _taximeter.setPlannedRoute(r.polyline);

        _offRouteSince = null;
        _offRouteHits = 0;
        _lastRerouteAt = DateTime.now();
        _distanceAtLastReroute = _taximeter.distanceMeters;
      } else {
        setState(() => _status = 'No se encontró ruta alternativa');
      }
    } catch (e) {
      setState(() => _status = 'Error al recalcular ruta: $e');
    } finally {
      _rerouting = false;
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String _formatEta(Duration d) {
    final mins = d.inMinutes;
    if (mins <= 0) return '<1 min';
    if (mins < 60) return '$mins min';
    final h = d.inHours;
    final m = mins.remainder(60);
    return '${h}h ${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kmLive = _taximeter.distanceMeters / 1000.0;

    final markers = <Marker>{
      if (_origin != null)
        Marker(
          markerId: const MarkerId('origin'),
          position: _origin!,
          infoWindow: const InfoWindow(title: 'Origen'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      if (_destination != null)
        Marker(
          markerId: const MarkerId('destination'),
          position: _destination!,
          infoWindow: const InfoWindow(title: 'Destino'),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
    };

    final polylines = <Polyline>{
      if (_route != null && _route!.polyline.length >= 2)
        Polyline(
          polylineId: const PolylineId('planned'),
          points: _route!.polyline,
          color: Colors.blue,
          width: 5,
        ),
      if (_taximeter.traveledPath.length >= 2)
        Polyline(
          polylineId: const PolylineId('traveled'),
          points: _taximeter.traveledPath,
          color: Colors.orange,
          width: 6,
        ),
    };

    final estFare = _estimatedFare();

    Widget fabSmall({
      required String tag,
      required VoidCallback? onPressed,
      required Widget child,
      bool active = true,
    }) {
      return FloatingActionButton.small(
        heroTag: tag,
        onPressed: onPressed,
        backgroundColor: Colors.white,
        foregroundColor: active ? scheme.primary : scheme.outline,
        child: child,
      );
    }

    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Taxi SCT'),
        actions: [
          IconButton(
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Limpiar',
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(target: _initialCenter, zoom: 14),
            onMapCreated: (c) => _map = c,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: false,
            onCameraMoveStarted: () {
              if (_isProgrammaticMove) return;
              if (_taximeter.running && _followCar) {
                setState(() => _followCar = false);
              }
            },
            markers: markers,
            polylines: polylines,
            onTap: _onMapTap,
          ),

          // Inputs arriba
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: (_phase == RidePhase.inTrip) ? 0.0 : 1.0,
            child: IgnorePointer(
              ignoring: _phase == RidePhase.inTrip,
              child: Align(
                alignment: Alignment.topCenter,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Card(
                      color: Colors.white.withOpacity(0.96),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PlaceAutocompleteField(
                              label: 'Origen (SLP)',
                              places: _places,
                              controller: _originCtl,
                              enabled: !_locked,
                              biasLat: _slpCenter.latitude,
                              biasLng: _slpCenter.longitude,
                              onSelected: (desc, placeId, token) {
                                _setOriginFromPlace(desc, placeId, token);
                              },
                            ),
                            const SizedBox(height: 10),
                            PlaceAutocompleteField(
                              label: 'Destino (SLP)',
                              places: _places,
                              controller: _destCtl,
                              enabled: !_locked,
                              biasLat: _slpCenter.latitude,
                              biasLng: _slpCenter.longitude,
                              onSelected: (desc, placeId, token) {
                                _setDestFromPlace(desc, placeId, token);
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // FABs derecha
          Positioned(
            right: 14,
            bottom: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                fabSmall(
                  tag: 'btn_fit_route',
                  onPressed: (_route != null && _route!.polyline.isNotEmpty)
                      ? () => _fitBounds(_route!.polyline)
                      : null,
                  child: const Icon(Icons.center_focus_strong),
                ),
                const SizedBox(height: 10),
                fabSmall(
                  tag: 'btn_follow',
                  onPressed: _taximeter.running
                      ? () {
                    setState(() => _followCar = true);
                    _maybeFollowCar(force: true);
                  }
                      : null,
                  active: _taximeter.running,
                  child: Icon(_followCar ? Icons.navigation : Icons.navigation_outlined),
                ),
                const SizedBox(height: 10),
                fabSmall(
                  tag: 'btn_my_location',
                  onPressed: _locating ? null : _goToMyLocation,
                  active: !_locating,
                  child: _locating
                      ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.my_location),
                ),
              ],
            ),
          ),

          // Bottom sheet
          DraggableScrollableSheet(
            initialChildSize: (_phase == RidePhase.inTrip) ? 0.30 : 0.26,
            minChildSize: (_phase == RidePhase.inTrip) ? 0.22 : 0.20,
            maxChildSize: 0.58,
            builder: (context, controller) {
              return Material(
                color: Colors.transparent,
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.97),
                      border: Border(top: BorderSide(color: scheme.outlineVariant)),
                    ),
                    child: ListView(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                      children: [
                        Center(
                          child: Container(
                            width: 42,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _status,
                          style: TextStyle(fontSize: 13, color: scheme.onSurface.withOpacity(0.75)),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 10),

                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<Shift>(
                                value: _taximeter.shift,
                                items: const [
                                  DropdownMenuItem(value: Shift.diurno, child: Text('Diurno')),
                                  DropdownMenuItem(value: Shift.nocturno, child: Text('Nocturno')),
                                ],
                                onChanged: _locked ? null : (v) => v != null ? _taximeter.setShift(v) : null,
                                decoration: const InputDecoration(labelText: 'Turno'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DropdownButtonFormField<ServiceChannel>(
                                value: _taximeter.channel,
                                items: const [
                                  DropdownMenuItem(value: ServiceChannel.calle, child: Text('Calle')),
                                  DropdownMenuItem(value: ServiceChannel.telefonico, child: Text('Telefónico')),
                                  DropdownMenuItem(value: ServiceChannel.app, child: Text('App')),
                                ],
                                onChanged: _locked ? null : (v) => v != null ? _taximeter.setChannel(v) : null,
                                decoration: const InputDecoration(labelText: 'Solicitud'),
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        if (_phase == RidePhase.routeReady && _route != null)
                          _SummaryCard(
                            title: 'Resumen del viaje',
                            rows: [
                              _SummaryRow('Distancia', '${_route!.distanceKm.toStringAsFixed(2)} km'),
                              _SummaryRow('Tiempo aprox.', _formatEta(_route!.duration)),
                              _SummaryRow(
                                'Tarifa estimada',
                                estFare == null ? '-' : '\$${estFare.toStringAsFixed(2)}',
                              ),
                            ],
                          ),

                        if (_phase == RidePhase.inTrip)
                          _SummaryCard(
                            title: 'En viaje',
                            rows: [
                              _SummaryRow('Tarifa', '\$${_taximeter.fare.toStringAsFixed(2)}', big: true),
                              _SummaryRow('Tiempo', _formatDuration(_taximeter.elapsed)),
                              _SummaryRow('Distancia', '${kmLive.toStringAsFixed(2)} km'),
                              _SummaryRow('Unidades', '${_taximeter.units}'),
                            ],
                          ),

                        if (_phase == RidePhase.finished)
                          _SummaryCard(
                            title: 'Viaje finalizado',
                            rows: [
                              _SummaryRow('Tarifa final', '\$${_taximeter.fare.toStringAsFixed(2)}', big: true),
                              _SummaryRow('Tiempo', _formatDuration(_taximeter.elapsed)),
                              _SummaryRow('Distancia', '${kmLive.toStringAsFixed(2)} km'),
                              _SummaryRow('Unidades', '${_taximeter.units}'),
                            ],
                          ),

                        const SizedBox(height: 12),

                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: (_origin != null && _destination != null && !_locked && !_loadingRoute)
                                    ? _calculateRoute
                                    : null,
                                icon: _loadingRoute
                                    ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                                    : const Icon(Icons.alt_route),
                                label: const Text('Calcular ruta'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  if (_startingTrip) return;

                                  if (_phase == RidePhase.routeReady) {
                                    await _startTrip();
                                  } else if (_phase == RidePhase.inTrip) {
                                    await _stopTrip();
                                  } else if (_phase == RidePhase.finished) {
                                    _clearAll();
                                  }
                                },
                                icon: _startingTrip
                                    ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                                    : Icon(
                                  _phase == RidePhase.inTrip
                                      ? Icons.stop
                                      : (_phase == RidePhase.finished ? Icons.refresh : Icons.play_arrow),
                                ),
                                label: Text(
                                  _startingTrip
                                      ? 'Iniciando...'
                                      : (_phase == RidePhase.inTrip
                                      ? 'Detener'
                                      : (_phase == RidePhase.finished ? 'Nuevo viaje' : 'Iniciar viaje')),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SummaryRow {
  final String label;
  final String value;
  final bool big;
  const _SummaryRow(this.label, this.value, {this.big = false});
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final List<_SummaryRow> rows;

  const _SummaryCard({
    super.key,
    required this.title,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Card(
      color: scheme.surfaceContainerHighest.withOpacity(0.55),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            for (final r in rows) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(r.label, style: TextStyle(color: scheme.onSurface.withOpacity(0.65))),
                  Text(
                    r.value,
                    style: TextStyle(
                      fontWeight: r.big ? FontWeight.w900 : FontWeight.w700,
                      fontSize: r.big ? 20 : 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }
}