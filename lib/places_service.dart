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

  PlacesService(
      this.apiKey, {
        this.restrictToSlp = false,
        LatLng? slpCenter,
        this.slpRadiusMeters = 45000, // 45 km aprox
      }) : slpCenter = slpCenter ?? const LatLng(22.1565, -100.9855);

  /// Token público (por si lo quieres manejar desde UI)
  String newSessionToken() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 32)}';
  }

  /// ✅ FIX: alias privado para evitar el error de _sessionToken no encontrado
  String _sessionToken() => newSessionToken();

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

    final preds = (body['predictions'] as List<dynamic>? ?? []);
    final items = preds.map((p) {
      final m = p as Map<String, dynamic>;
      return PlacePrediction(
        placeId: (m['place_id'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
      );
    }).where((p) => p.placeId.isNotEmpty && p.description.isNotEmpty).toList();

    if (items.length <= maxResults) return items;
    return items.take(maxResults).toList();
  }

  /// Devuelve null si:
  /// - no hay geometry
  /// - y/o requireSlp=true y el lugar NO pertenece al estado de San Luis Potosí
  Future<LatLng?> placeIdToLatLng(
      String placeId, {
        String? sessionToken,
        bool requireSlp = false,
      }) async {
    final token = (sessionToken != null && sessionToken.isNotEmpty)
        ? sessionToken
        : _sessionToken();

    // Si quieres “forzar” que sea SLP, necesitamos address_components
    final mustCheckSlp = requireSlp || restrictToSlp;
    final fields = mustCheckSlp ? 'geometry/location,address_components' : 'geometry/location';

    final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
      'place_id': placeId,
      'key': apiKey,
      'language': 'es',
      'fields': fields,
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

    if (mustCheckSlp) {
      final comps = (result['address_components'] as List<dynamic>? ?? const []);
      if (comps.isEmpty) return null;
      if (!_isSanLuisPotosi(comps)) return null;
    }

    final geom = result['geometry'] as Map<String, dynamic>?;
    final loc = geom?['location'] as Map<String, dynamic>?;
    final lat = (loc?['lat'] as num?)?.toDouble();
    final lng = (loc?['lng'] as num?)?.toDouble();

    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  bool _isSanLuisPotosi(List<dynamic> components) {
    String? stateLong;
    String? countryShort;

    for (final c in components) {
      final m = c as Map<String, dynamic>;
      final types = (m['types'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList();

      if (types.contains('administrative_area_level_1')) {
        stateLong = (m['long_name'] ?? '').toString();
      }
      if (types.contains('country')) {
        countryShort = (m['short_name'] ?? '').toString();
      }
    }

    final normalized = (stateLong ?? '')
        .toLowerCase()
        .replaceAll('ó', 'o')
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ú', 'u');

    return countryShort == 'MX' && normalized.contains('san luis potosi');
  }
}