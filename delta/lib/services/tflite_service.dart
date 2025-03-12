import 'dart:io';
import 'package:tflite_flutter/tflite_flutter.dart';

class TFLiteService {
  Interpreter? _interpreter;

  Future<void> loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/soil_npk_model.tflite',
      );
      print("TFLite model loaded successfully.");
    } catch (e) {
      print("Error loading model: $e");
    }
  }

  List<double> predict(List<double> inputData) {
    if (_interpreter == null) {
      throw Exception("Model is not loaded yet.");
    }

    var input = inputData; // Model expects 2D array
    var output = List.generate(
      1,
      (index) => List.filled(3, 0.0),
    ); // Output NPK values

    _interpreter!.run(input, output);
    return output[0]; // Returns [Nitrogen, Phosphorus, Potassium]
  }

  Future<void> runPrediction() async {
    await loadModel(); // Load the model

    print("Enter pH value:");
    double ph = double.parse(stdin.readLineSync()!);

    print("Enter EC (Electrical Conductivity) value:");
    double ec = double.parse(stdin.readLineSync()!);

    print("Enter Moisture value:");
    double moisture = double.parse(stdin.readLineSync()!);

    List<double> inputData = [ph, ec, moisture];
    List<double> npkValues = predict(inputData);

    print("\nPredicted NPK values:");
    print("Nitrogen: ${npkValues[0]}");
    print("Phosphorus: ${npkValues[1]}");
    print("Potassium: ${npkValues[2]}");
  }
}

// // Run directly for testing
// void main() async {
//   TFLiteService tfliteService = TFLiteService();
//   await tfliteService.runPrediction();
// }
