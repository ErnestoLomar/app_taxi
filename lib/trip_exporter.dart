import 'dart:convert';
import 'dart:io';

import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'taximeter_controller.dart';

class TripExportResult {
  final Directory directory;
  final File jsonFile;
  final File csvFile;

  TripExportResult({
    required this.directory,
    required this.jsonFile,
    required this.csvFile,
  });
}

class TripExporter {
  /// Guarda JSON + CSV en Documents de la app y abre el share sheet.
  static Future<TripExportResult> exportAndShare({
    required TaximeterController taxi,
    LatLng? origin,
    LatLng? destination,
    String? originLabel,
    String? destinationLabel,
    List<LatLng>? plannedRoute,
  }) async {
    final dir = await getApplicationDocumentsDirectory();

    final safeTs = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final baseName = 'trip_$safeTs';

    final jsonPath = '${dir.path}/$baseName.json';
    final csvPath = '${dir.path}/$baseName.csv';

    final exportJson = taxi.buildTripExport(
      origin: origin,
      destination: destination,
      originLabel: originLabel,
      destinationLabel: destinationLabel,
      plannedRoute: plannedRoute,
    );

    final jsonFile = File(jsonPath);
    await jsonFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(exportJson),
      flush: true,
    );

    final csvFile = File(csvPath);
    await csvFile.writeAsString(
      _buildCsv(taxi),
      flush: true,
    );

    await Share.shareXFiles(
      [
        XFile(jsonFile.path, mimeType: 'application/json'),
        XFile(csvFile.path, mimeType: 'text/csv'),
      ],
      text: 'Export del viaje (Taxi SCT)',
    );

    return TripExportResult(directory: dir, jsonFile: jsonFile, csvFile: csvFile);
  }

  static String _buildCsv(TaximeterController taxi) {
    final b = StringBuffer();

    // Header
    b.writeln([
      'time_iso',
      'elapsed_ms',
      'accepted',
      'reason',
      'raw_lat',
      'raw_lng',
      'filtered_lat',
      'filtered_lng',
      'used_lat',
      'used_lng',
      'snapped',
      'dist_to_route_m',
      'accuracy_m',
      'speed_mps',
      'heading_deg',
      'delta_m',
      'dt_s',
      'cum_distance_m',
      'units',
      'fare',
    ].join(','));

    for (final s in taxi.samples) {
      b.writeln([
        _csv(s.time.toIso8601String()),
        s.elapsedMs,
        s.accepted ? 1 : 0,
        _csv(s.reason),
        s.raw.latitude,
        s.raw.longitude,
        s.filtered.latitude,
        s.filtered.longitude,
        s.used.latitude,
        s.used.longitude,
        s.snapped ? 1 : 0,
        _numOrEmpty(s.distToRouteMeters),
        _numOrEmpty(s.accuracy),
        _numOrEmpty(s.speed),
        _numOrEmpty(s.heading),
        _numOrEmpty(s.deltaMeters),
        _numOrEmpty(s.dtSeconds),
        _numOrEmpty(s.cumulativeDistanceMeters),
        s.units,
        s.fare.toStringAsFixed(2),
      ].join(','));
    }

    return b.toString();
  }

  static String _csv(String v) {
    if (v.contains(',') || v.contains('"') || v.contains('\n')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  static String _numOrEmpty(num? v) => (v == null || !v.isFinite) ? '' : v.toString();
}