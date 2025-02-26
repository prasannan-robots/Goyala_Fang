import 'package:flutter/material.dart';
// Import packages for communication (e.g., flutter_blue for Bluetooth)
// import 'package:flutter_background_messenger/flutter_background_messenger.dart';
import 'package:flutter_sms/flutter_sms.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import 'package:google_places_flutter/model/place_type.dart';
import 'package:google_places_flutter/model/prediction.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: SmsPage());
  }
}

class SmsPage extends StatefulWidget {
  @override
  _SmsPageState createState() => _SmsPageState();
}

class _SmsPageState extends State<SmsPage> {
  // Initialize communication (e.g., Bluetooth)
  String receivedMessage = "";
  //  final messenger = FlutterBackgroundMessenger();

  @override
  void initState() {
    super.initState();
    // Set up communication listener
    //  sendSMS();
  }
  // void _sendSMS(String message, List<String> recipents) async {
  //  String _result = await sendSMS(message: message, recipients: recipents)
  //         .catchError((onError) {
  //       print(onError);
  //     });
  // print(_result);
  // }
  // Future<void> sendSMS() async {
  //   try {
  //     final success = await messenger.sendSMS(
  //       phoneNumber: '+917825033051',
  //       message: 'Hello from Flutter Background Messenger!',
  //     );

  //     if (success) {
  //       print('SMS sent successfully');
  //     } else {
  //       print('Failed to send SMS');
  //     }
  //   } catch (e) {
  //     print('Error sending SMS: $e');
  //   }
  // }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('GSM SMS Controller')),
      body: Column(
        children: [
          Text('Received: $receivedMessage'),
          TextField(
            onSubmitted: (text) {
              //sendSMS();
            },
            decoration: InputDecoration(labelText: 'Enter message'),
          ),
        ],
      ),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  _MapScreenState createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final TextEditingController _sourceController = TextEditingController();
  final TextEditingController _destinationController = TextEditingController();
  final TextEditingController _rangeController = TextEditingController();
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  bool _isLoading = false;

  bool _searchByOpeningHours = false;
  LatLng _currentPosition = const LatLng(
    13.085758559399656,
    80.1754404576725,
  ); // Example start location
  // 11.387819148378416, 79.73058865396625
  @override
  void initState() {
    super.initState();
    _getCurrentLocation();
  }

  Future<Position> determinePosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled don't continue
      // accessing the position and request users of the
      // App to enable the location services.
      return Future.error('Location services are disabled.');
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied, next time you could try
        // requesting permissions again (this is also where
        // Android's shouldShowRequestPermissionRationale
        // returned true. According to Android guidelines
        // your App should show an explanatory UI now.
        return Future.error('Location permissions are denied');
      }
    }

    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever, handle appropriately.
      return Future.error(
        'Location permissions are permanently denied, we cannot request permissions.',
      );
    }

    // When we reach here, permissions are granted and we can
    // continue accessing the position of the device.
    return await Geolocator.getCurrentPosition();
  }

  Future<void> _getCurrentLocation() async {
    Position position = await determinePosition();
    setState(() {
      _currentPosition = LatLng(position.latitude, position.longitude);
    });
  }

  void _showSearchOptionsDialog() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Search Options'),
          content: const Text('Do you want to search by opening hours?'),
          actions: <Widget>[
            TextButton(
              child: const Text('No'),
              onPressed: () {
                setState(() {
                  _searchByOpeningHours = false;
                });
                Navigator.of(context).pop();
              },
            ),
            TextButton(
              child: const Text('Yes'),
              onPressed: () {
                setState(() {
                  _searchByOpeningHours = true;
                });
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Charger'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSearchOptionsDialog,
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _currentPosition,
              zoom: 12,
            ),
            markers: _markers,
            polylines: _polylines,
            onMapCreated: (GoogleMapController controller) {},
          ),
          Positioned(
            left: 0,
            right: 0,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  children: [
                    GooglePlaceAutoCompleteTextField(
                      textEditingController: _sourceController,
                      googleAPIKey: "AIzaSyD-tezFTBpKRVH1icGYGyJUP4SQPyUrPaE",
                      inputDecoration: const InputDecoration(
                        label: Text('Enter Source'),
                      ),
                      debounceTime: 800, // default 600 ms,
                      countries: const [
                        "in",
                        "fr",
                      ], // optional by default null is set
                      isLatLngRequired:
                          true, // if you required coordinates from place detail
                      getPlaceDetailWithLatLng: (Prediction prediction) {
                        // this method will return latlng with place detail
                        print("placeDetails" + prediction.lng.toString());
                        _sourceController.text =
                            '${prediction.lat.toString()},${prediction.lng.toString()}';
                      }, // this callback is called when isLatLngRequired is true
                      itemClick: (Prediction prediction) {},
                      // if we want to make custom list item builder
                      itemBuilder: (context, index, Prediction prediction) {
                        return Container(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              const Icon(Icons.location_on),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text("${prediction.description ?? ""}"),
                              ),
                            ],
                          ),
                        );
                      },
                      // if you want to add seperator between list items
                      seperatedBuilder: const Divider(),
                      // want to show close icon
                      isCrossBtnShown: true,
                      // optional container padding
                      containerHorizontalPadding: 10,
                      // place type
                      placeType: PlaceType.geocode,
                    ),
                    const SizedBox(height: 10),
                    GooglePlaceAutoCompleteTextField(
                      textEditingController: _destinationController,
                      googleAPIKey: "AIzaSyD-tezFTBpKRVH1icGYGyJUP4SQPyUrPaE",
                      inputDecoration: const InputDecoration(
                        label: Text('Enter Destination'),
                      ),
                      debounceTime: 800, // default 600 ms,
                      countries: const [
                        "in",
                        "fr",
                      ], // optional by default null is set
                      isLatLngRequired:
                          true, // if you required coordinates from place detail
                      getPlaceDetailWithLatLng: (Prediction prediction) {
                        // this method will return latlng with place detail
                        print("placeDetails" + prediction.lng.toString());
                        _destinationController.text =
                            '${prediction.lat.toString()},${prediction.lng.toString()}';
                      }, // this callback is called when isLatLngRequired is true
                      itemClick: (Prediction prediction) {
                        // _destinationController.selection =
                        //     TextSelection.fromPosition(TextPosition(
                        //         offset:
                        //             prediction.description?.length ?? 0));
                      },
                      // if we want to make custom list item builder
                      itemBuilder: (context, index, Prediction prediction) {
                        return Container(
                          padding: const EdgeInsets.all(10),
                          child: Row(
                            children: [
                              const Icon(Icons.location_on),
                              const SizedBox(width: 7),
                              Expanded(
                                child: Text("${prediction.description ?? ""}"),
                              ),
                            ],
                          ),
                        );
                      },
                      // if you want to add seperator between list items
                      seperatedBuilder: const Divider(),
                      // want to show close icon
                      isCrossBtnShown: true,
                      // optional container padding
                      containerHorizontalPadding: 10,
                      // place type
                      placeType: PlaceType.geocode,
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _rangeController,
                      decoration: InputDecoration(
                        hintText: 'Enter vehicle range',
                        filled: true,
                        fillColor: Colors.white,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8.0),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_isLoading) const Center(child: CircularProgressIndicator()),
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
