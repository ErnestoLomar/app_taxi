import 'package:google_maps_flutter/google_maps_flutter.dart';

class RouteInfo {
  final List<LatLng> polyline;
  final int distanceMeters;
  final int durationSeconds;

  const RouteInfo({
    required this.polyline,
    required this.distanceMeters,
    required this.durationSeconds,
  });

  Duration get duration => Duration(seconds: durationSeconds);
  double get distanceKm => distanceMeters / 1000.0;
}