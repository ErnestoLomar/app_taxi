import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_info.dart';

class DirectionsService {
  final String apiKey;
  DirectionsService(this.apiKey);

  Future<RouteInfo> fetchRoute({
    required LatLng origin,
    required LatLng destination,
  }) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&mode=driving'
          '&overview=full'
          '&key=$apiKey',
    );

    final res = await http.get(url);
    if (res.statusCode != 200) {
      throw Exception('Directions HTTP ${res.statusCode}');
    }

    final jsonBody = json.decode(res.body) as Map<String, dynamic>;
    final status = (jsonBody['status'] ?? '').toString();

    if (status != 'OK') {
      final msg = (jsonBody['error_message'] ?? '').toString();
      throw Exception('Directions $status ${msg.isEmpty ? "" : "- $msg"}');
    }

    final routes = (jsonBody['routes'] as List<dynamic>);
    if (routes.isEmpty) {
      return const RouteInfo(polyline: [], distanceMeters: 0, durationSeconds: 0);
    }

    final route0 = routes.first as Map<String, dynamic>;

    // Distancia/duración (primer leg)
    int dist = 0;
    int dur = 0;
    final legs = (route0['legs'] as List<dynamic>? ?? []);
    if (legs.isNotEmpty) {
      final leg0 = legs.first as Map<String, dynamic>;
      dist = ((leg0['distance']?['value'] as num?) ?? 0).toInt();
      dur = ((leg0['duration']?['value'] as num?) ?? 0).toInt();
    }

    // Polyline
    final poly = (route0['overview_polyline']?['points'] ?? '').toString();
    if (poly.isEmpty) {
      return RouteInfo(polyline: const [], distanceMeters: dist, durationSeconds: dur);
    }

    final points = PolylinePoints().decodePolyline(poly);
    final ll = points.map((p) => LatLng(p.latitude, p.longitude)).toList();

    return RouteInfo(polyline: ll, distanceMeters: dist, durationSeconds: dur);
  }
}