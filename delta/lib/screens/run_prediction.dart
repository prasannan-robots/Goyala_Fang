import 'package:flutter/material.dart';
import '../services/tflite_service.dart'; // Import the TFLite service

class PredictionScreen extends StatefulWidget {
  @override
  _PredictionScreenState createState() => _PredictionScreenState();
}

class _PredictionScreenState extends State<PredictionScreen> {
  final TFLiteService _tfliteService = TFLiteService();
  List<double>? prediction;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    await _tfliteService.loadModel();
  }

  void _predictNPK() {
    List<double> inputData = [6.8, 2.1, 45]; // Example input: pH, EC, Moisture
    setState(() {
      prediction = _tfliteService.predict(inputData);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Soil NPK Predictor")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text("Click to Predict NPK Values"),
            ElevatedButton(onPressed: _predictNPK, child: Text("Predict")),
            if (prediction != null)
              Text(
                "N: ${prediction![0]}, P: ${prediction![1]}, K: ${prediction![2]}",
              ),
          ],
        ),
      ),
    );
  }
}
