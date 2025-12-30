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

  PlacesService(this.apiKey);

  String _sessionToken() {
    final r = Random();
    return '${DateTime.now().millisecondsSinceEpoch}-${r.nextInt(1 << 32)}';
  }

  Future<List<PlacePrediction>> autocomplete(
      String input, {
        LatLng? locationBias,
        int radiusMeters = 30000,
      }) async {
    final q = input.trim();
    if (q.length < 3) return [];

    final token = _sessionToken();

    final params = <String, String>{
      'input': q,
      'key': apiKey,
      'language': 'es',
      'components': 'country:mx',
      'sessiontoken': token,
    };

    // Opcional: sesgar resultados hacia SLP (mejor UX)
    if (locationBias != null) {
      params['location'] = '${locationBias.latitude},${locationBias.longitude}';
      params['radius'] = radiusMeters.toString();
      params['strictbounds'] = 'true';
    }

    final uri = Uri.https('maps.googleapis.com', '/maps/api/place/autocomplete/json', params);

    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('Places Autocomplete HTTP ${res.statusCode}');
    }

    final body = json.decode(res.body) as Map<String, dynamic>;
    final status = (body['status'] ?? '').toString();
    if (status != 'OK' && status != 'ZERO_RESULTS') {
      final msg = (body['error_message'] ?? '').toString();
      throw Exception('Places Autocomplete $status ${msg.isEmpty ? "" : "- $msg"}');
    }

    final preds = (body['predictions'] as List<dynamic>? ?? []);
    return preds.map((p) {
      final m = p as Map<String, dynamic>;
      return PlacePrediction(
        placeId: (m['place_id'] ?? '').toString(),
        description: (m['description'] ?? '').toString(),
      );
    }).where((p) => p.placeId.isNotEmpty && p.description.isNotEmpty).toList();
  }

  Future<LatLng?> placeIdToLatLng(String placeId) async {
    final token = _sessionToken();

    final uri = Uri.https('maps.googleapis.com', '/maps/api/place/details/json', {
      'place_id': placeId,
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
    final geom = result?['geometry'] as Map<String, dynamic>?;
    final loc = geom?['location'] as Map<String, dynamic>?;
    final lat = (loc?['lat'] as num?)?.toDouble();
    final lng = (loc?['lng'] as num?)?.toDouble();

    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }
}