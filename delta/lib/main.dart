import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:another_telephony/telephony.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:intl/intl.dart';

@pragma('vm:entry-point')
onBackgroundMessage(SmsMessage message) {
  debugPrint("onBackgroundMessage called");
}

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: MapScreen());
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  Set<Polygon> _polygons = {};
  Set<Circle> _circles = {};
  bool _isLoading = false;
  bool _isSelecting = false;
  bool _showWaypointScale = false;

  LatLng _currentPosition = LatLng(12.824518906843178, 80.04677754205541);
  late GoogleMapController _mapController;

  List<LatLng> _polygonLatLngs = [];
  List<LatLng> _waypoints = [];
  int _numWaypoints = 10; // Default number of waypoints
  String receivedDataBuffer = "";
  final Telephony telephony = Telephony.instance;
  final TextEditingController _phoneNumberController = TextEditingController();
  Interpreter? _interpreter;

  String _sensorInfo = '';
  String _predictedData = '';

  final _bluetoothClassicPlugin = BluetoothClassic();
  List<Device> _bluetoothDevices = [];
  Device? _selectedDevice;
  Uint8List _data = Uint8List(0);
  String _transmissionMode = 'SMS'; // Default transmission mode

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    _loadModel();
    _listenForSms();
    _initBluetooth();
  }

  bool _isBluetoothInitializing = false;

  Future<void> _initBluetooth() async {
    try {
      await _bluetoothClassicPlugin.initPermissions();

      //await _bluetoothClassicPlugin.stopScan();
      setState(() {});
    } catch (e) {
      print("Error initializing Bluetooth: $e");
    }
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/soil_npk_model.tflite',
      );
      print("TFLite model loaded successfully.");
    } catch (e) {
      print("Error loading model: $e");
    }
  }

  List<double> _predict(List<double> inputData) {
    if (_interpreter == null) {
      throw Exception("Model is not loaded yet.");
    }

    var input = inputData; // Model expects 2D array
    var output = List.generate(
      1,
      (index) => List.filled(3, 0.0),
    ); // Output NPK values

    _interpreter!.run(input, output);
    print(output);
    return output[0]; // Returns [Nitrogen, Phosphorus, Potassium]
  }

  Future<Position> determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return Future.error(
        'Location permissions are permanently denied, we cannot request permissions.',
      );
    }

    return await Geolocator.getCurrentPosition();
  }

  Future<void> _getCurrentLocation() async {
    Position position = await determinePosition();
    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
      _markers.add(
        Marker(
          markerId: MarkerId('currentLocation'),
          position: _currentPosition,
          infoWindow: InfoWindow(title: 'Current Location'),
        ),
      );
    });
    _mapController.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _currentPosition, zoom: 200),
      ),
    );
  }

  void _onMapTapped(LatLng latLng) {
    if (!_isSelecting) return;

    setState(() {
      _polygonLatLngs.add(latLng);
      _markers.add(
        Marker(
          markerId: MarkerId(latLng.toString()),
          position: latLng,
          draggable: true,
          onDragEnd: (newPosition) {
            setState(() {
              _polygonLatLngs[_polygonLatLngs.indexOf(latLng)] = newPosition;
              _updatePolygon();
            });
          },
        ),
      );
      if (_polygonLatLngs.length == 4) {
        _updatePolygon();
        _generateWaypoints();
      }
    });
  }

  void _updatePolygon() {
    setState(() {
      _polygons.clear();
      _polygons.add(
        Polygon(
          polygonId: PolygonId('selectedArea'),
          points: _polygonLatLngs,
          strokeColor: Colors.blue,
          strokeWidth: 2,
          fillColor: Colors.blue.withOpacity(0.15),
        ),
      );
    });
  }

  void _generateWaypoints() {
    if (_polygonLatLngs.length != 4) return;

    _waypoints.clear();

    // Calculate the bounding box
    double minLat =
        _polygonLatLngs.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
    double maxLat =
        _polygonLatLngs.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);
    double minLng =
        _polygonLatLngs.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
    double maxLng =
        _polygonLatLngs.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);

    // Generate waypoints evenly distributed within the bounding box
    double latStep = (maxLat - minLat) / (_numWaypoints / 2);
    double lngStep = (maxLng - minLng) / (_numWaypoints / 2);

    for (double lat = minLat; lat <= maxLat; lat += latStep) {
      for (double lng = minLng; lng <= maxLng; lng += lngStep) {
        LatLng waypoint = LatLng(lat, lng);
        if (_isPointInPolygon(waypoint, _polygonLatLngs)) {
          _waypoints.add(waypoint);
        }
      }
    }

    // Add waypoints as markers
    for (LatLng waypoint in _waypoints) {
      _markers.add(
        Marker(
          markerId: MarkerId(waypoint.toString()),
          position: waypoint,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueBlue,
          ),
        ),
      );
    }
  }

  bool _isPointInPolygon(LatLng point, List<LatLng> polygon) {
    int intersectCount = 0;
    for (int j = 0; j < polygon.length - 1; j++) {
      if (_rayCastIntersect(point, polygon[j], polygon[j + 1])) {
        intersectCount++;
      }
    }
    return (intersectCount % 2) == 1; // odd = inside, even = outside;
  }

  bool _rayCastIntersect(LatLng point, LatLng vertA, LatLng vertB) {
    double aY = vertA.latitude;
    double bY = vertB.latitude;
    double aX = vertA.longitude;
    double bX = vertB.longitude;
    double pY = point.latitude;
    double pX = point.longitude;

    if ((aY > pY && bY > pY) || (aY < pY && bY < pY) || (aX < pX && bX < pX)) {
      return false;
    }

    double m = (aY - bY) / (aX - bX);
    double bee = (-aX) * m + aY;
    double x = (pY - bee) / m;

    return x > pX;
  }

  void _clearSelection() {
    setState(() {
      _polygonLatLngs.clear();
      _markers.clear();
      _polygons.clear();
      _waypoints.clear();
      _circles.clear();
    });
  }

  void _focusCurrentLocation() {
    _mapController.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _currentPosition, zoom: 12),
      ),
    );
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelecting = !_isSelecting;
    });
  }

  void _toggleWaypointScale() {
    setState(() {
      _showWaypointScale = !_showWaypointScale;
    });
  }

  String _waypointsToString() {
    return _waypoints.map((wp) => '${wp.latitude},${wp.longitude}').join('; ');
  }

  void _sendWaypoints() async {
    print("sending...");

    String message = _waypointsToString();
    int chunkSize = 160 - 4; // Adjust for "GPS: " prefix
    List<String> messageChunks = [];
    List<String> waypoints = message.split('; ');

    StringBuffer currentChunk = StringBuffer();

    for (String waypoint in waypoints) {
      if (currentChunk.length + waypoint.length + 2 > chunkSize) {
        messageChunks.add("GPS: " + currentChunk.toString());
        currentChunk.clear();
      }
      if (currentChunk.isNotEmpty) {
        currentChunk.write('; ');
      }
      currentChunk.write(waypoint);
    }

    if (currentChunk.isNotEmpty) {
      messageChunks.add("GPS: " + currentChunk.toString());
    }

    if (_transmissionMode == 'SMS') {
      // Send each chunk as a separate SMS
      for (String chunk in messageChunks) {
        await telephony.sendSms(
          to: _phoneNumberController
              .text, // Use the phone number from the input field
          message: chunk,
        );
      }
      await telephony.sendSms(
        to: _phoneNumberController
            .text, // Use the phone number from the input field
        message: "Start",
      );
    } else if (_transmissionMode == 'Bluetooth' && _selectedDevice != null) {
      // Send data via Bluetooth
      for (String chunk in messageChunks) {
        await _bluetoothClassicPlugin.write(chunk);
      }
      await _bluetoothClassicPlugin.write("Start");
    }

    print("Sent");
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Waypoints sent successfully!')));
  }

  void _listenForSms() {
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        print("Incoming SMS: ${message.address} - ${message.body}");
        if (message.address == _phoneNumberController.text) {
          print("GOing in");
          _processReceivedSms(message.body ?? '');
        }
      },
      listenInBackground: false,
    );
  }

  void _processReceivedSms(String message) {
    // Example message format: "Lat:12.3456,Lng:78.9012,Sensor:1.23-4.56-7.89"
    message = message.replaceFirst(";", "");
    if (message.startsWith('S:')) {
      message = message.replaceFirst('S:', '');

      final parts = message.split(',');
      print(parts);

      final lat = double.tryParse(parts[0].split(':')[1]);
      final lng = double.tryParse(parts[1].split(':')[1]);
      final sensorData = parts[2]
          .split(':')[1]
          .split('-')
          .map((e) => double.tryParse(e))
          .toList();
      print(lat);
      print(lng);
      print(sensorData);
      if (lat != null && lng != null && sensorData.every((e) => e != null)) {
        final position = LatLng(lat, lng);
        List<double> sensorData2 = sensorData.cast<double>();

        sensorData2 = _predict(sensorData2);
        print('HELOO');
        print(sensorData2);

        _sensorInfo =
            '${sensorData[0]!.toStringAsFixed(2)}pH - ${sensorData[1]!.toStringAsFixed(2)} Moisture';
        _predictedData =
            '${sensorData2[0].toStringAsFixed(2)}N ${sensorData2[1].toStringAsFixed(2)}P ${sensorData2[2].toStringAsFixed(2)}K';
        final output = _predictedData;
        print("Received data: $_sensorInfo");

        setState(() {
          _markers.removeWhere((marker) => marker.position == position);

          _markers.add(
            Marker(
              markerId: MarkerId(position.toString()),
              position: position,
              icon: BitmapDescriptor.defaultMarkerWithHue(
                BitmapDescriptor.hueGreen,
              ),
              infoWindow: InfoWindow(
                title: 'Received Data',
                snippet: output,
                onTap: () => _showBottomSheet(
                    context, _sensorInfo, _predictedData, sensorData2),
              ),
            ),
          );
          Color circleColor = _getColorBasedOnNPK(
              sensorData2[0], sensorData2[1], sensorData2[2]);
          _circles.add(
            Circle(
              circleId: CircleId(position.toString()),
              center: position,
              radius: 3.66, // 12 feet in meters
              strokeColor: circleColor,
              strokeWidth: 2,
              fillColor: circleColor.withOpacity(0.15),
            ),
          );
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Received data: $_sensorInfo')));
      }
    } else if (message.startsWith('C:')) {
      message = message.replaceFirst('C:', '');
      final parts = message.split(',');
      print(parts);

      final lat = double.tryParse(parts[0].split(':')[1]);
      final lng = double.tryParse(parts[1].split(':')[1]);
      if (lat != null && lng != null) {
        final position = LatLng(lat, lng);
        final output = _predictedData;
        print("Received data: $_sensorInfo");

        setState(() {
          _markers.removeWhere((marker) => marker.position == position);

          _markers.add(Marker(
            markerId: MarkerId(position.toString()),
            position: position,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            infoWindow: InfoWindow(
              title: 'Robot',
              snippet: output,
            ),
          ));
        });
      }
    }
  }

  List<String> suggestCrops(
      double nitrogen, double phosphorus, double potassium) {
    // Define common NPK ratios and their associated crops
    final npkCrops = {
      "high_nitrogen": {
        "ratio": [30.0, 10.0, 10.0], // Example ratio for leafy greens
        "crops": ["Lettuce", "Spinach", "Kale"]
      },
      "high_phosphorus": {
        "ratio": [10.0, 30.0, 20.0], // Example ratio for fruits
        "crops": ["Apples", "Oranges", "Grapes"]
      },
      "balanced": {
        "ratio": [20.0, 20.0, 20.0], // Balanced ratio for general use
        "crops": ["Corn", "Wheat", "Soybeans"]
      },
      "high_potassium": {
        "ratio": [10.0, 10.0, 30.0], // Example ratio for disease resistance
        "crops": ["Potatoes", "Tomatoes", "Peppers"]
      }
    };

    // Calculate the closest match
    String? closestMatch;
    double minDiff = double.infinity;

    npkCrops.forEach((npkType, details) {
      final ratio = details["ratio"] as List<double>;
      final ratioDiff = (nitrogen - ratio[0]).abs() +
          (phosphorus - ratio[1]).abs() +
          (potassium - ratio[2]).abs();
      if (ratioDiff < minDiff) {
        minDiff = ratioDiff;
        closestMatch = npkType;
      }
    });

    // Return suggested crops based on the closest match
    if (closestMatch != null) {
      return npkCrops[closestMatch]!["crops"] as List<String>;
    } else {
      return [
        "No specific match found. Consider a balanced NPK ratio like 20-20-20."
      ];
    }
  }

  void _showBottomSheet(BuildContext context, String sensorInfo,
      String predictedData, List<double> npkValues) {
    print("hlo");
    final suggestedCrops =
        suggestCrops(npkValues[0], npkValues[1], npkValues[2]);

    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        return Container(
          width: double.infinity,
          padding: EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sensor Data',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(sensorInfo),
              SizedBox(height: 10),
              Text('Predicted Data',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(predictedData),
              SizedBox(height: 10),
              Text('Suggested Crops',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              Text(suggestedCrops.join(', ')),
            ],
          ),
        );
      },
    );
  }

  Color _getColorBasedOnNPK(
      double nitrogen, double phosphorus, double potassium) {
    // Define thresholds for NPK values
    const double highThreshold = 10.0;
    const double mediumThreshold = 5.0;
    const double phighThreshold = 6.0;
    const double pmediumThreshold = 4.0;
    const double khighThreshold = 10.0;
    const double kmediumThreshold = 8.0;

    if (nitrogen > highThreshold &&
        phosphorus > phighThreshold &&
        potassium > khighThreshold) {
      return Colors.green;
    } else if (nitrogen > mediumThreshold &&
        phosphorus > pmediumThreshold &&
        potassium > kmediumThreshold) {
      return Colors.yellow;
    } else {
      return Colors.red;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delta'),
        actions: [
          IconButton(icon: Icon(Icons.delete), onPressed: _clearSelection),
          IconButton(
            icon: Icon(Icons.settings),
            onPressed: _toggleWaypointScale,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_showWaypointScale)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  TextField(
                    decoration: InputDecoration(
                      labelText: 'Scale',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      setState(() {
                        _numWaypoints = int.tryParse(value) ?? 10;
                      });
                    },
                  ),
                  SizedBox(height: 10),
                  DropdownButton<String>(
                    value: _transmissionMode,
                    items: <String>['SMS', 'Bluetooth']
                        .map<DropdownMenuItem<String>>((String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    }).toList(),
                    onChanged: (String? newValue) async {
                      if (newValue == 'Bluetooth') {
                        await _initBluetooth();

                        try {
                          _bluetoothDevices =
                              await _bluetoothClassicPlugin.getPairedDevices();
                        } catch (e) {
                          print(e);
                        }

                        try {
                          _bluetoothClassicPlugin.onDeviceDiscovered().listen(
                            (event) {
                              _bluetoothDevices = [..._bluetoothDevices, event];
                            },
                          );
                          await _bluetoothClassicPlugin.startScan();
                        } catch (e) {
                          print(e);
                        }
                        print(_bluetoothDevices);
                        try {
                          _bluetoothClassicPlugin
                              .onDeviceDataReceived()
                              .listen((event) {
                            setState(() {
                              _data = Uint8List.fromList([..._data, ...event]);
                              String receivedString = utf8.decode(event);

                              receivedDataBuffer += receivedString;
                              print(receivedString);
                              if (receivedString.contains(';')) {
                                print("Buffer");
                                print(receivedDataBuffer);
                                _processReceivedSms(receivedDataBuffer);
                                receivedDataBuffer = '';
                              }
                            });
                          });
                        } catch (e) {
                          print(e);
                        }
                      }
                      setState(() {
                        _transmissionMode = newValue!;
                      });
                    },
                  ),
                  if (_transmissionMode == 'SMS')
                    TextField(
                      controller: _phoneNumberController,
                      decoration: InputDecoration(
                        labelText: 'Phone Number',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.phone,
                    ),
                  if (_transmissionMode == 'Bluetooth')
                    DropdownButton<Device>(
                      value: _selectedDevice,
                      items: _bluetoothDevices
                          .map<DropdownMenuItem<Device>>((Device device) {
                        return DropdownMenuItem<Device>(
                          value: device,
                          child: Text(device.name ?? 'Unknown Device'),
                        );
                      }).toList(),
                      onChanged: (Device? newValue) async {
                        try {
                          await _bluetoothClassicPlugin.stopScan();
                          await _bluetoothClassicPlugin.connect(
                            newValue!.address,
                            "00001101-0000-1000-8000-00805f9b34fb",
                          );
                          setState(() {
                            _selectedDevice = newValue;
                          });
                        } catch (e) {
                          print("Error connecting to device: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(
                                    'Failed to connect to device: ${newValue?.name ?? 'Unknown Device'}')),
                          );
                        }
                      },
                    ),
                ],
              ),
            ),
          Expanded(
            child: GoogleMap(
              mapType: MapType.satellite, // Set the map type to satellite
              initialCameraPosition: CameraPosition(
                target: LatLng(
                  0,
                  0,
                ), // Default position before getting current location
                zoom: 12,
              ),
              markers: _markers,
              circles: _circles,
              polylines: _polylines,
              polygons: _polygons,
              onMapCreated: (GoogleMapController controller) {
                _mapController = controller;
              },
              onTap: _onMapTapped,
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton(
            onPressed: _toggleSelectionMode,
            child: Icon(_isSelecting ? Icons.check : Icons.edit),
          ),
          SizedBox(height: 10),
          FloatingActionButton(
            onPressed: _focusCurrentLocation,
            child: Icon(Icons.my_location),
          ),
          SizedBox(height: 10),
          FloatingActionButton(
            onPressed: _sendWaypoints,
            child: Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

LatLng _parseLatLng(String input) {
  final parts = input.split(',');
  if (parts.length == 2) {
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat != null && lng != null) {
      return LatLng(lat, lng);
    }
  }
  return const LatLng(0.0, 0.0);
}
