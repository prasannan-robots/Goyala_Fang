import 'package:google_maps_flutter/google_maps_flutter.dart';

/// One soil sample reported by the robot.
class SoilReading {
  const SoilReading({
    required this.position,
    required this.sensorValues,
    this.npk,
  });

  final LatLng position;

  /// `[pH, EC, moisture]` - the inputs the NPK model was trained on. Older
  /// robot firmware sends only `[pH, moisture]`.
  final List<double> sensorValues;

  /// Predicted `[N, P, K]` in kg/ha, or `null` if the model couldn't run.
  final List<double>? npk;

  double get ph => sensorValues.first;
  double? get ec => sensorValues.length >= 3 ? sensorValues[1] : null;
  double get moisture => sensorValues.last;
}

class CropProfile {
  const CropProfile(this.name, this.npk, this.crops);
  final String name;
  final List<double> npk;
  final List<String> crops;
}

const cropProfiles = [
  CropProfile('High nitrogen', [30, 10, 10],
      ['Lettuce', 'Spinach', 'Kale', 'Hybrid Rice']),
  CropProfile('High phosphorus', [10, 30, 20],
      ['Apples', 'Oranges', 'Grapes', 'Black Gram']),
  CropProfile('Balanced', [20, 20, 20],
      ['Corn', 'Wheat', 'Soybeans', 'Groundnut']),
  CropProfile('High potassium', [10, 10, 30],
      ['Potatoes', 'Tomatoes', 'Peppers', 'Maize']),
];

/// The crop profile whose NPK needs are closest to the measured soil.
CropProfile closestProfile(List<double> npk) {
  double distance(CropProfile p) =>
      (npk[0] - p.npk[0]).abs() +
      (npk[1] - p.npk[1]).abs() +
      (npk[2] - p.npk[2]).abs();
  return cropProfiles.reduce((a, b) => distance(a) <= distance(b) ? a : b);
}

class FertilizerAdvice {
  const FertilizerAdvice(this.profile, this.n, this.p, this.k, this.cost);
  final CropProfile profile;

  /// kg/ha still needed. Never negative: surplus nutrients need no fertilizer.
  final double n, p, k;
  final double cost;
}

List<FertilizerAdvice> fertilizerAdvice(
  List<double> npk, {
  double costPerKg = 50,
}) {
  double need(double target, double have) => target > have ? target - have : 0;
  return [
    for (final profile in cropProfiles)
      () {
        final n = need(profile.npk[0], npk[0]);
        final p = need(profile.npk[1], npk[1]);
        final k = need(profile.npk[2], npk[2]);
        return FertilizerAdvice(profile, n, p, k, (n + p + k) * costPerKg);
      }(),
  ];
}

/// Average predicted NPK over the readings that have a prediction, or `null`
/// if none do.
List<double>? averageNpk(Iterable<SoilReading> readings) {
  final predicted = readings.map((r) => r.npk).whereType<List<double>>();
  if (predicted.isEmpty) return null;
  final sum = [0.0, 0.0, 0.0];
  for (final npk in predicted) {
    for (var i = 0; i < 3; i++) {
      sum[i] += npk[i];
    }
  }
  return sum.map((v) => v / predicted.length).toList();
}

enum SoilHealth { good, fair, poor }

SoilHealth soilHealth(List<double> npk) {
  final [n, p, k] = npk;
  if (n > 10 && p > 6 && k > 10) return SoilHealth.good;
  if (n > 5 && p > 4 && k > 8) return SoilHealth.fair;
  return SoilHealth.poor;
}
