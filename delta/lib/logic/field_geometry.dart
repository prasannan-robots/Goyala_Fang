import 'dart:math';

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Even-odd ray casting ("PNPOLY"). Handles vertical edges and implicitly
/// closes the polygon (last vertex back to the first).
bool isPointInPolygon(LatLng point, List<LatLng> polygon) {
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final yi = polygon[i].latitude, xi = polygon[i].longitude;
    final yj = polygon[j].latitude, xj = polygon[j].longitude;
    final crosses = (yi > point.latitude) != (yj > point.latitude);
    if (crosses &&
        point.longitude < (xj - xi) * (point.latitude - yi) / (yj - yi) + xi) {
      inside = !inside;
    }
  }
  return inside;
}

/// Orders corners by angle around their centroid, so the field outline never
/// crosses itself no matter which order the corners were tapped in.
List<LatLng> orderCorners(List<LatLng> corners) {
  if (corners.length < 3) return List.of(corners);
  final cLat = corners.map((p) => p.latitude).reduce((a, b) => a + b) /
      corners.length;
  final cLng = corners.map((p) => p.longitude).reduce((a, b) => a + b) /
      corners.length;
  double angle(LatLng p) => atan2(p.latitude - cLat, p.longitude - cLng);
  return List.of(corners)..sort((a, b) => angle(a).compareTo(angle(b)));
}

/// Survey waypoints on a [gridSize] x [gridSize] grid laid over the field's
/// bounding box, keeping only points inside the field.
///
/// Points are cell centres (so none sit on the boundary) and are ordered as a
/// serpentine path, so the robot sweeps row by row instead of driving back
/// across the field at the end of every row.
List<LatLng> generateWaypoints(List<LatLng> field, {int gridSize = 5}) {
  if (field.length < 3 || gridSize < 1) return const [];
  final lats = field.map((p) => p.latitude);
  final lngs = field.map((p) => p.longitude);
  final minLat = lats.reduce(min), maxLat = lats.reduce(max);
  final minLng = lngs.reduce(min), maxLng = lngs.reduce(max);
  // A degenerate (zero-area) selection used to make the old loop spin forever.
  if (maxLat - minLat < 1e-9 || maxLng - minLng < 1e-9) return const [];

  final latStep = (maxLat - minLat) / gridSize;
  final lngStep = (maxLng - minLng) / gridSize;
  final waypoints = <LatLng>[];
  for (var row = 0; row < gridSize; row++) {
    final lat = minLat + (row + 0.5) * latStep;
    final rowPoints = [
      for (var col = 0; col < gridSize; col++)
        LatLng(lat, minLng + (col + 0.5) * lngStep),
    ].where((p) => isPointInPolygon(p, field));
    waypoints.addAll(row.isEven ? rowPoints : rowPoints.toList().reversed);
  }
  return waypoints;
}
