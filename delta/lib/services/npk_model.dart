import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// The bundled soil model: `[pH, EC, moisture]` -> `[N, P, K]` (kg/ha).
class NpkModel {
  NpkModel._(this._interpreter, this.inputSize);

  final Interpreter _interpreter;

  /// Number of sensor values the model expects (3 for the bundled model).
  final int inputSize;

  static Future<NpkModel> load() async {
    final interpreter =
        await Interpreter.fromAsset('assets/soil_npk_model.tflite');
    return NpkModel._(interpreter, interpreter.getInputTensor(0).shape.last);
  }

  /// Predicted `[N, P, K]`, or `null` when the reading doesn't have the
  /// values the model needs (e.g. firmware that sends no EC value).
  List<double>? predict(List<double> sensorValues) {
    if (sensorValues.length != inputSize) return null;
    try {
      final output = [List<double>.filled(3, 0)];
      _interpreter.run([sensorValues], output);
      return output.first;
    } catch (e) {
      debugPrint('NPK prediction failed: $e');
      return null;
    }
  }

  void close() => _interpreter.close();
}
