import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

class PlacePrediction {
  final String placeId;
  final String description;

  const PlacePrediction({
    required this.placeId,
    required this.description,
  });
}

class PlacesService {
  final String apiKey;

  /// Si true: Autocomplete queda “encerrado” en SLP (círculo + strictbounds)
  final bool restrictToSlp;

  /// Centro de referencia (ciudad de San Luis Potosí)
  final LatLng slpCenter;

  /// Radio en metros para “SLP” (ajústalo)
  final int slpRadiusMeters;

  /// Cache de Place Details (placeId -> LatLng)
  final Duration detailsTtl;
  final int detailsMaxEntries;

  final LinkedHashMap<String, _LatLngCacheEntry> _detailsCache = LinkedHashMap();

  PlacesService(
      this.apiKey, {
        this.restrictToSlp = false,
        LatLng? slpCenter,
        this.slpRadiusMeters = 45000, // 45 km aprox
        this.detailsTtl = const Duration(minutes: 30),
        this.detailsMaxEntries = 200,
      }) : slpCenter = slpCenter ?? const LatLng(22.1565, -100.9855);

  /// Token público (por si lo quieres manejar desde UI)
  String newSessionToken() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 32)}';
  }

  String _sessionToken() => newSessionToken();

  /// -----------------------------
  /// AUTOCOMPLETE (Places)
  /// -----------------------------
  Future<List<PlacePrediction>> autocomplete(
      String input, {
        LatLng? locationBias,
        int radiusMeters = 30000,
        String? sessionToken,
        int maxResults = 6,
      }) async {
    final q = input.trim();
    if (q.length < 3) return [];

    final token = (sessionToken == null || sessionToken.trim().isEmpty)
        ? newSessionToken()
        : sessionToken.trim();

    final params = <String, String>{
      'input': q,
      'key': apiKey,
      'language': 'es',
      'components': 'country:mx',
      'sessiontoken': token,
      'types': 'geocode',
    };

    final LatLng? bias = restrictToSlp ? slpCenter : locationBias;
    final int rad = restrictToSlp ? slpRadiusMeters : radiusMeters;

    if (bias != null) {
      params['location'] = '${bias.latitude},${bias.longitude}';
      params['radius'] = rad.toString();
      params['strictbounds'] = 'true';
    }

    final uri = Uri.https(
      'maps.googleapis.com',
      '/maps/api/place/autocomplete/json',
      params,
    );

    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Places Autocomplete HTTP ${res.statusCode}');
    }

    final body = json.decode(res.body) as Map<String, dynamic>;
    final status = (body['status'] ?? '').toString();

    if (status != 'OK' && status != 'ZERO_RESULTS') {
      final msg = (body['error_message'] ?? '').toString();
      throw Exception('Places Autocomplete $status${msg.isEmpty ? "" : " - $msg"}');
    }

    final preds = (body['predictions'] as List<dynamic>? ?? const []);
    final items = preds
        .map((p) {
      final m = p as Map<String, dynamic>;
      return PlacePrediction(
        placeId: (m['place_id'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
      );
    })
        .where((p) => p.placeId.isNotEmpty && p.description.isNotEmpty)
        .toList();

    if (items.length <= maxResults) return items;
    return items.take(maxResults).toList();
  }

  /// -----------------------------
  /// DETAILS: placeId -> LatLng
  /// -----------------------------
  ///
  /// Optimización de costo:
  /// - por defecto SOLO pedimos geometry/location
  /// - validación SLP por radio (no por address_components)
  /// - cache LRU con TTL para no repetir Place Details
  Future<LatLng?> placeIdToLatLng(
      String placeId, {
        String? sessionToken,
        bool requireSlp = false,
        bool bypassCache = false,
      }) async {
    final id = placeId.trim();
    if (id.isEmpty) return null;

    if (!bypassCache) {
      final cached = _getFromCache(id);
      if (cached != null) return cached;
    }

    final token = (sessionToken != null && sessionToken.isNotEmpty)
        ? sessionToken
        : _sessionToken();

    // 👇 IMPORTANTE: SOLO geometry/location (barato)
    final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
      'place_id': id,
      'key': apiKey,
      'language': 'es',
      'fields': 'geometry/location',
      'sessiontoken': token,
    });

    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Place Details HTTP ${res.statusCode}');
    }

    final body = json.decode(res.body) as Map<String, dynamic>;
    final status = (body['status'] ?? '').toString();
    if (status != 'OK') {
      final msg = (body['error_message'] ?? '').toString();
      throw Exception('Place Details $status ${msg.isEmpty ? "" : "- $msg"}');
    }

    final result = body['result'] as Map<String, dynamic>?;
    if (result == null) return null;

    final geom = result['geometry'] as Map<String, dynamic>?;
    final loc = geom?['location'] as Map<String, dynamic>?;
    final lat = (loc?['lat'] as num?)?.toDouble();
    final lng = (loc?['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final ll = LatLng(lat, lng);

    // Validación SLP por radio/círculo (sin pedir address_components)
    final mustCheckSlp = requireSlp || restrictToSlp;
    if (mustCheckSlp) {
      final d = _haversineMeters(ll, slpCenter);
      if (d > slpRadiusMeters) {
        return null;
      }
    }

    _putCache(id, ll);
    return ll;
  }

  /// -----------------------------
  /// Cache LRU con TTL
  /// -----------------------------
  LatLng? _getFromCache(String placeId) {
    final entry = _detailsCache.remove(placeId); // LRU
    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expiresAt)) {
      return null;
    }

    _detailsCache[placeId] = entry;
    return entry.value;
  }

  void _putCache(String placeId, LatLng value) {
    _detailsCache.remove(placeId);
    _detailsCache[placeId] = _LatLngCacheEntry(value, DateTime.now().add(detailsTtl));

    while (_detailsCache.length > detailsMaxEntries) {
      _detailsCache.remove(_detailsCache.keys.first);
    }
  }

  void clearDetailsCache() => _detailsCache.clear();

  /// -----------------------------
  /// Distancia Haversine (sin geolocator)
  /// -----------------------------
  static const double _R = 6371000.0;

  double _haversineMeters(LatLng a, LatLng b) {
    final dLat = _deg2rad(b.latitude - a.latitude);
    final dLon = _deg2rad(b.longitude - a.longitude);
    final lat1 = _deg2rad(a.latitude);
    final lat2 = _deg2rad(b.latitude);

    final h = sin(dLat / 2) * sin(dLat / 2) +
        cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2);
    final c = 2 * atan2(sqrt(h), sqrt(1 - h));
    return _R * c;
  }

  double _deg2rad(double d) => d * pi / 180.0;
}

class _LatLngCacheEntry {
  final LatLng value;
  final DateTime expiresAt;
  const _LatLngCacheEntry(this.value, this.expiresAt);
}