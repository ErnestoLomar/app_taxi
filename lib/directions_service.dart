import 'dart:collection';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'route_info.dart';

class DirectionsService {
  final String apiKey;

  /// Cache: evita volver a cobrar por recalcular la misma ruta
  final Duration ttl;
  final int maxEntries;

  final LinkedHashMap<_RouteKey, _CacheEntry> _cache = LinkedHashMap();

  DirectionsService(
      this.apiKey, {
        this.ttl = const Duration(minutes: 5),
        this.maxEntries = 60,
      });

  void clearCache() => _cache.clear();

  Future<RouteInfo> fetchRoute({
    required LatLng origin,
    required LatLng destination,
    bool forceRefresh = false,
  }) async {
    final key = _RouteKey.from(origin, destination);

    if (!forceRefresh) {
      final cached = _getValidFromCache(key);
      if (cached != null) return cached;
    }

    final route = await _fetchRouteNetwork(origin: origin, destination: destination);
    _putCache(key, route);
    return route;
  }

  RouteInfo? _getValidFromCache(_RouteKey key) {
    final entry = _cache.remove(key); // LRU: lo sacamos para reinsertarlo al final
    if (entry == null) return null;

    if (DateTime.now().isAfter(entry.expiresAt)) {
      return null;
    }

    _cache[key] = entry;
    return entry.value;
  }

  void _putCache(_RouteKey key, RouteInfo value) {
    _cache.remove(key);
    _cache[key] = _CacheEntry(value, DateTime.now().add(ttl));

    while (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  Future<RouteInfo> _fetchRouteNetwork({
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
      throw Exception('Directions $status${msg.isEmpty ? "" : " - $msg"}');
    }

    final routes = (jsonBody['routes'] as List<dynamic>? ?? const []);
    if (routes.isEmpty) {
      return const RouteInfo(polyline: [], distanceMeters: 0, durationSeconds: 0);
    }

    final route0 = routes.first as Map<String, dynamic>;

    int dist = 0;
    int dur = 0;
    final legs = (route0['legs'] as List<dynamic>? ?? const []);
    if (legs.isNotEmpty) {
      final leg0 = legs.first as Map<String, dynamic>;
      dist = ((leg0['distance']?['value'] as num?) ?? 0).toInt();
      dur = ((leg0['duration']?['value'] as num?) ?? 0).toInt();
    }

    final poly = (route0['overview_polyline']?['points'] ?? '').toString();
    if (poly.isEmpty) {
      return RouteInfo(polyline: const [], distanceMeters: dist, durationSeconds: dur);
    }

    final points = PolylinePoints().decodePolyline(poly);
    final ll = points.map((p) => LatLng(p.latitude, p.longitude)).toList();

    return RouteInfo(polyline: ll, distanceMeters: dist, durationSeconds: dur);
  }
}

class _RouteKey {
  final int oLatE5, oLngE5, dLatE5, dLngE5;

  const _RouteKey(this.oLatE5, this.oLngE5, this.dLatE5, this.dLngE5);

  factory _RouteKey.from(LatLng o, LatLng d) {
    int e5(double v) => (v * 1e5).round(); // redondeo para evitar “casi igual”
    return _RouteKey(e5(o.latitude), e5(o.longitude), e5(d.latitude), e5(d.longitude));
  }

  @override
  bool operator ==(Object other) =>
      other is _RouteKey &&
          oLatE5 == other.oLatE5 &&
          oLngE5 == other.oLngE5 &&
          dLatE5 == other.dLatE5 &&
          dLngE5 == other.dLngE5;

  @override
  int get hashCode => Object.hash(oLatE5, oLngE5, dLatE5, dLngE5);
}

class _CacheEntry {
  final RouteInfo value;
  final DateTime expiresAt;
  const _CacheEntry(this.value, this.expiresAt);
}