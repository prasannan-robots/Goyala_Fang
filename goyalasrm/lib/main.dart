import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import 'package:google_places_flutter/model/place_type.dart';
import 'package:google_places_flutter/model/prediction.dart';
import 'package:another_telephony/telephony.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

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
  bool _isLoading = false;
  bool _isSelecting = false;
  bool _showWaypointScale = false;

  late LatLng _currentPosition;
  late GoogleMapController _mapController;

  List<LatLng> _polygonLatLngs = [];
  List<LatLng> _waypoints = [];
  int _numWaypoints = 10; // Default number of waypoints

  final Telephony telephony = Telephony.instance;
  final TextEditingController _phoneNumberController = TextEditingController();
  Interpreter? _interpreter;

  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
    _loadModel();
    _listenForSms();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset(
        'assets/soil_npk_model.tflite',
      );
      print("TFLite model loaded successfully.");
      _predict([1, 2, 3]);
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
        CameraPosition(target: _currentPosition, zoom: 12),
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
    double minLat = _polygonLatLngs
        .map((p) => p.latitude)
        .reduce((a, b) => a < b ? a : b);
    double maxLat = _polygonLatLngs
        .map((p) => p.latitude)
        .reduce((a, b) => a > b ? a : b);
    double minLng = _polygonLatLngs
        .map((p) => p.longitude)
        .reduce((a, b) => a < b ? a : b);
    double maxLng = _polygonLatLngs
        .map((p) => p.longitude)
        .reduce((a, b) => a > b ? a : b);

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
            BitmapDescriptor.hueGreen,
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

    // Send each chunk as a separate SMS
    for (String chunk in messageChunks) {
      await telephony.sendSms(
        to:
            _phoneNumberController
                .text, // Use the phone number from the input field
        message: chunk,
      );
    }

    print("Sent");
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Waypoints sent successfully!')));
  }

  void _listenForSms() {
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) {
        if (message.address == _phoneNumberController.text) {
          _processReceivedSms(message.body ?? '');
        }
      },
      listenInBackground: false,
    );
  }

  void _processReceivedSms(String message) {
    // Example message format: "Lat:12.3456,Lng:78.9012,Sensor:1.23,4.56,7.89"
    final parts = message.split(',');
    if (parts.length >= 5) {
      final lat = double.tryParse(parts[0].split(':')[1]);
      final lng = double.tryParse(parts[1].split(':')[1]);
      final sensorData =
          parts
              .sublist(2)
              .map((e) => double.tryParse(e.split(':')[1]))
              .toList();

      if (lat != null && lng != null && sensorData.every((e) => e != null)) {
        final position = LatLng(lat, lng);
        final sensorInfo = 'Sensor Data: ${sensorData.join(', ')}';

        setState(() {
          _markers.add(
            Marker(
              markerId: MarkerId(position.toString()),
              position: position,
              infoWindow: InfoWindow(
                title: 'Received Data',
                snippet: sensorInfo,
              ),
            ),
          );
        });

        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Received data: $sensorInfo')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delta Farmer'),
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
                      labelText: 'Number of Waypoints',
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
                  TextField(
                    controller: _phoneNumberController,
                    decoration: InputDecoration(
                      labelText: 'Phone Number',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.phone,
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
