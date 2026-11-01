import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:another_telephony/telephony.dart';
import 'package:bluetooth_classic/bluetooth_classic.dart';
import 'package:bluetooth_classic/models/device.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import 'logic/field_geometry.dart';
import 'logic/robot_protocol.dart';
import 'logic/soil_advisor.dart';
import 'services/npk_model.dart';

/// Standard Bluetooth Serial Port Profile UUID (HC-05/HC-06 style modules).
const _sppUuid = '00001101-0000-1000-8000-00805f9b34fb';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en', 'US'), Locale('ta', 'IN')],
      path: 'assets/translations',
      fallbackLocale: const Locale('ta', 'IN'),
      child: const SagaApp(),
    ),
  );
}

class SagaApp extends StatelessWidget {
  const SagaApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF2E7D32); // field green
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (_) => 'appTitle'.tr(),
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: ThemeData(colorSchemeSeed: seed),
      darkTheme: ThemeData(colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const FieldMapScreen(),
    );
  }
}

enum LinkMode { sms, bluetooth }

class FieldMapScreen extends StatefulWidget {
  const FieldMapScreen({super.key});

  @override
  State<FieldMapScreen> createState() => _FieldMapScreenState();
}

class _FieldMapScreenState extends State<FieldMapScreen> {
  static const _fallbackCenter = LatLng(12.8245, 80.0468);

  final _telephony = Telephony.instance;
  final _bluetooth = BluetoothClassic();
  final _phoneController = TextEditingController();
  StreamSubscription<Uint8List>? _bluetoothData;
  String _bluetoothBuffer = '';

  GoogleMapController? _map;
  LatLng? _here;
  NpkModel? _model;

  LinkMode _mode = LinkMode.sms;
  List<Device> _devices = const [];
  Device? _device;
  bool _connecting = false;

  bool _marking = false;
  List<LatLng> _corners = [];
  List<LatLng> _waypoints = const [];
  int _gridSize = 5;
  bool _sending = false;

  final List<SoilReading> _readings = [];
  LatLng? _robot;

  bool get _linkReady => _mode == LinkMode.sms
      ? _phoneController.text.trim().isNotEmpty
      : _device != null;

  @override
  void initState() {
    super.initState();
    _locate();
    _loadModel();
    _listenForSms();
  }

  @override
  void dispose() {
    _bluetoothData?.cancel();
    _phoneController.dispose();
    _map?.dispose();
    _model?.close();
    super.dispose();
  }

  // ---------------------------------------------------------------- setup --

  Future<void> _loadModel() async {
    try {
      final model = await NpkModel.load();
      if (!mounted) return model.close();
      setState(() => _model = model);
    } catch (e) {
      debugPrint('Could not load NPK model: $e');
    }
  }

  Future<void> _listenForSms() async {
    try {
      // SEND/RECEIVE_SMS are runtime permissions on Android 6+; without
      // asking, sending fails and incoming robot messages never arrive.
      final granted = await _telephony.requestPhoneAndSmsPermissions ?? false;
      if (!granted) return;
      _telephony.listenIncomingSms(
        onNewMessage: (message) {
          if (_mode == LinkMode.sms &&
              samePhoneNumber(message.address, _phoneController.text)) {
            _handleRobotMessage(message.body ?? '');
          }
        },
        listenInBackground: false,
      );
    } catch (e) {
      debugPrint('SMS unavailable on this device: $e');
    }
  }

  Future<void> _locate({bool userAsked = false}) async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      final allowed = permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always;
      if (!allowed || !await Geolocator.isLocationServiceEnabled()) {
        if (userAsked) _toast('locationUnavailable'.tr());
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final here = LatLng(position.latitude, position.longitude);
      setState(() => _here = here);
      await _map?.animateCamera(CameraUpdate.newLatLngZoom(here, 18));
    } catch (e) {
      if (userAsked) _toast('locationUnavailable'.tr());
    }
  }

  // --------------------------------------------------------- field marking --

  void _onMapTap(LatLng point) {
    if (!_marking || _corners.length >= 4) return;
    setState(() {
      _corners.add(point);
      if (_corners.length == 4) {
        _marking = false;
        _corners = orderCorners(_corners);
        _waypoints = generateWaypoints(_corners, gridSize: _gridSize);
      }
    });
  }

  void _moveCorner(int index, LatLng to) {
    setState(() {
      _corners[index] = to;
      if (_corners.length == 4) {
        _corners = orderCorners(_corners);
        _waypoints = generateWaypoints(_corners, gridSize: _gridSize);
      }
    });
  }

  void _toggleMarking() {
    setState(() {
      if (!_marking && _corners.length == 4) {
        // Start over with a new field.
        _corners = [];
        _waypoints = const [];
      }
      _marking = !_marking;
    });
  }

  void _clearField() {
    setState(() {
      _corners = [];
      _waypoints = const [];
      _readings.clear();
      _robot = null;
      _marking = false;
    });
  }

  // ----------------------------------------------------------- robot link --

  Future<void> _sendWaypoints() async {
    if (_waypoints.isEmpty) {
      _toast('markFieldFirst'.tr());
      return;
    }
    if (!_linkReady) {
      _toast(_mode == LinkMode.sms
          ? 'enterPhoneFirst'.tr()
          : 'selectDeviceFirst'.tr());
      _openConnectionSheet();
      return;
    }
    final messages = [...encodeWaypointMessages(_waypoints), 'Start'];
    setState(() => _sending = true);
    try {
      for (final message in messages) {
        switch (_mode) {
          case LinkMode.sms:
            await _telephony.sendSms(
              to: _phoneController.text.trim(),
              message: message,
            );
          case LinkMode.bluetooth:
            await _bluetooth.write('$message\n');
        }
      }
      _toast('waypointsSentSuccessfully'.tr());
    } catch (e) {
      _toast('sendFailed'.tr(namedArgs: {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _refreshDevices() async {
    try {
      await _bluetooth.initPermissions();
      final paired = await _bluetooth.getPairedDevices();
      if (mounted) setState(() => _devices = paired);
    } catch (e) {
      _toast('errorLoadingDevices'.tr());
    }
  }

  Future<void> _connect(Device device) async {
    setState(() => _connecting = true);
    try {
      await _bluetooth.connect(device.address, _sppUuid);
      // Subscribe once; the old code added a new listener on every mode
      // change, so each message was processed several times.
      _bluetoothData ??=
          _bluetooth.onDeviceDataReceived().listen(_onBluetoothData);
      if (mounted) setState(() => _device = device);
    } catch (e) {
      _toast('connectFailed'.tr(namedArgs: {'device': device.name ?? device.address}));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onBluetoothData(Uint8List bytes) {
    final (messages, rest) = splitMessages(
      _bluetoothBuffer + utf8.decode(bytes, allowMalformed: true),
    );
    // Drop runaway partial data instead of growing the buffer forever.
    _bluetoothBuffer = rest.length > 2048 ? '' : rest;
    messages.forEach(_handleRobotMessage);
  }

  void _handleRobotMessage(String raw) {
    final message = parseRobotMessage(raw);
    if (!mounted || message == null) return;
    switch (message) {
      case SensorMessage(:final position, :final values):
        final reading = SoilReading(
          position: position,
          sensorValues: values,
          npk: _model?.predict(values),
        );
        setState(() {
          _readings.removeWhere((r) => r.position == position);
          _readings.add(reading);
        });
        _toast('receivedData'.tr(namedArgs: {'sensorInfo': _describe(reading)}));
      case PositionMessage(:final position):
        setState(() => _robot = position);
      case SurveyDoneMessage():
        _showReport();
    }
  }

  // -------------------------------------------------------------- helpers --

  String _describe(SoilReading r) {
    final ec = r.ec;
    return [
      'pH ${r.ph.toStringAsFixed(2)}',
      if (ec != null) 'EC ${ec.toStringAsFixed(2)}',
      '${'moisture'.tr()} ${r.moisture.toStringAsFixed(1)}',
    ].join(' · ');
  }

  String _formatNpk(List<double> npk) =>
      'N ${npk[0].toStringAsFixed(1)} · P ${npk[1].toStringAsFixed(1)} · '
      'K ${npk[2].toStringAsFixed(1)} kg/ha';

  Color _healthColor(SoilHealth health) => switch (health) {
        SoilHealth.good => Colors.green,
        SoilHealth.fair => Colors.amber,
        SoilHealth.poor => Colors.red,
      };

  double _healthHue(SoilHealth health) => switch (health) {
        SoilHealth.good => BitmapDescriptor.hueGreen,
        SoilHealth.fair => BitmapDescriptor.hueYellow,
        SoilHealth.poor => BitmapDescriptor.hueRed,
      };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------ map layers --

  Set<Marker> get _markers => {
        for (final (i, corner) in _corners.indexed)
          Marker(
            markerId: MarkerId('corner-$i'),
            position: corner,
            draggable: true,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            onDragEnd: (to) => _moveCorner(i, to),
          ),
        for (final (i, reading) in _readings.indexed)
          Marker(
            markerId: MarkerId('reading-$i'),
            position: reading.position,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              reading.npk == null
                  ? BitmapDescriptor.hueAzure
                  : _healthHue(soilHealth(reading.npk!)),
            ),
            infoWindow: InfoWindow(
              title: reading.npk == null
                  ? _describe(reading)
                  : _formatNpk(reading.npk!),
              snippet: 'predictedData'.tr(),
              onTap: () => _showReading(reading),
            ),
          ),
        if (_robot != null)
          Marker(
            markerId: const MarkerId('robot'),
            position: _robot!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueViolet,
            ),
            infoWindow: InfoWindow(title: 'robot'.tr()),
          ),
      };

  Set<Polygon> get _polygons => _corners.length < 3
      ? const {}
      : {
          Polygon(
            polygonId: const PolygonId('field'),
            points: _corners,
            strokeColor: Colors.white,
            strokeWidth: 2,
            fillColor: Colors.white.withValues(alpha: 0.15),
          ),
        };

  Set<Polyline> get _polylines => _waypoints.length < 2
      ? const {}
      : {
          Polyline(
            polylineId: const PolylineId('survey-path'),
            points: _waypoints,
            color: Colors.lightBlueAccent,
            width: 2,
            patterns: [PatternItem.dash(8), PatternItem.gap(6)],
          ),
        };

  Set<Circle> get _circles => {
        for (final (i, wp) in _waypoints.indexed)
          Circle(
            circleId: CircleId('wp-$i'),
            center: wp,
            radius: 0.8,
            strokeWidth: 1,
            strokeColor: Colors.white,
            fillColor: Colors.lightBlueAccent,
          ),
        for (final (i, reading) in _readings.indexed)
          if (reading.npk != null)
            Circle(
              circleId: CircleId('sample-$i'),
              center: reading.position,
              radius: 3.66, // 12 ft sampling radius
              strokeWidth: 2,
              strokeColor: _healthColor(soilHealth(reading.npk!)),
              fillColor: _healthColor(soilHealth(reading.npk!))
                  .withValues(alpha: 0.15),
            ),
      };

  // -------------------------------------------------------------------- UI --

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('appTitle'.tr()),
        actions: [
          IconButton(
            tooltip: 'connectionSettings'.tr(),
            onPressed: _openConnectionSheet,
            icon: Icon(
              _mode == LinkMode.sms ? Icons.sms_outlined : Icons.bluetooth,
              color: _linkReady ? null : Theme.of(context).colorScheme.error,
            ),
          ),
          PopupMenuButton<Locale>(
            tooltip: 'language'.tr(),
            icon: const Icon(Icons.translate),
            onSelected: context.setLocale,
            itemBuilder: (_) => const [
              PopupMenuItem(value: Locale('en', 'US'), child: Text('English')),
              PopupMenuItem(value: Locale('ta', 'IN'), child: Text('தமிழ்')),
            ],
          ),
          IconButton(
            tooltip: 'clearField'.tr(),
            onPressed: _corners.isEmpty && _readings.isEmpty ? null : _clearField,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            mapType: MapType.hybrid,
            initialCameraPosition: CameraPosition(
              target: _here ?? _fallbackCenter,
              zoom: 17,
            ),
            myLocationEnabled: _here != null,
            myLocationButtonEnabled: false,
            markers: _markers,
            polygons: _polygons,
            polylines: _polylines,
            circles: _circles,
            onMapCreated: (controller) => _map = controller,
            onTap: _onMapTap,
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: _StatusCard(
              text: _statusText,
              icon: _statusIcon,
              action: _statusAction,
            ),
          ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'locate',
            tooltip: 'myLocation'.tr(),
            onPressed: () => _locate(userAsked: true),
            child: const Icon(Icons.my_location),
          ),
          const SizedBox(height: 12),
          if (_readings.isNotEmpty) ...[
            FloatingActionButton.extended(
              heroTag: 'report',
              onPressed: _showReport,
              icon: const Icon(Icons.assessment_outlined),
              label: Text('viewReport'.tr()),
            ),
            const SizedBox(height: 12),
          ],
          FloatingActionButton.extended(
            heroTag: 'mark',
            onPressed: _toggleMarking,
            icon: Icon(_marking ? Icons.close : Icons.crop_free),
            label: Text(_marking ? 'cancel'.tr() : 'markField'.tr()),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'send',
            onPressed: _sending || _waypoints.isEmpty ? null : _sendWaypoints,
            backgroundColor: _waypoints.isEmpty
                ? Theme.of(context).disabledColor.withValues(alpha: 0.12)
                : null,
            icon: _sending
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send),
            label: Text(_sending ? 'sending'.tr() : 'sendToRobot'.tr()),
          ),
        ],
      ),
    );
  }

  String get _statusText {
    if (_marking) {
      return 'tapCorners'.tr(namedArgs: {'count': '${_corners.length}'});
    }
    if (_readings.isNotEmpty) {
      return 'readingsCount'.tr(namedArgs: {'count': '${_readings.length}'});
    }
    if (_waypoints.isNotEmpty) {
      return 'waypointsReady'.tr(namedArgs: {'count': '${_waypoints.length}'});
    }
    if (!_linkReady) return 'notConnected'.tr();
    return 'selectAnAreaOnTheMap'.tr();
  }

  IconData get _statusIcon {
    if (_marking) return Icons.touch_app_outlined;
    if (_readings.isNotEmpty) return Icons.grass;
    if (_waypoints.isNotEmpty) return Icons.route;
    if (!_linkReady) return Icons.link_off;
    return Icons.crop_free;
  }

  Widget? get _statusAction {
    if (!_marking && !_linkReady) {
      return TextButton(
        onPressed: _openConnectionSheet,
        child: Text('connect'.tr()),
      );
    }
    if (_marking && _corners.isNotEmpty) {
      return TextButton(
        onPressed: () => setState(() => _corners.removeLast()),
        child: Text('undo'.tr()),
      );
    }
    return null;
  }

  // --------------------------------------------------------------- sheets --

  void _openConnectionSheet() {
    if (_mode == LinkMode.bluetooth && _devices.isEmpty) _refreshDevices();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          void update(VoidCallback change) {
            setState(change);
            setSheetState(() {});
          }

          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              20 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'connectionSettings'.tr(),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SegmentedButton<LinkMode>(
                  segments: const [
                    ButtonSegment(
                      value: LinkMode.sms,
                      icon: Icon(Icons.sms_outlined),
                      label: Text('SMS'),
                    ),
                    ButtonSegment(
                      value: LinkMode.bluetooth,
                      icon: Icon(Icons.bluetooth),
                      label: Text('Bluetooth'),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (selection) {
                    update(() => _mode = selection.first);
                    if (_mode == LinkMode.bluetooth && _devices.isEmpty) {
                      _refreshDevices().then((_) => setSheetState(() {}));
                    }
                  },
                ),
                const SizedBox(height: 16),
                if (_mode == LinkMode.sms)
                  TextField(
                    controller: _phoneController,
                    keyboardType: TextInputType.phone,
                    onChanged: (_) => update(() {}),
                    decoration: InputDecoration(
                      labelText: 'phoneNumber'.tr(),
                      hintText: '+91 98765 43210',
                      prefixIcon: const Icon(Icons.phone),
                      border: const OutlineInputBorder(),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'selectBluetoothDevice'.tr(),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            _refreshDevices().then((_) => setSheetState(() {})),
                        icon: const Icon(Icons.refresh),
                        label: Text('refresh'.tr()),
                      ),
                    ],
                  ),
                  if (_devices.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text('noBluetoothDevicesFound'.tr()),
                    ),
                  for (final device in _devices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.memory),
                      title: Text(device.name ?? device.address),
                      subtitle: Text(device.address),
                      trailing: _device?.address == device.address
                          ? Chip(label: Text('connected'.tr()))
                          : FilledButton.tonal(
                              onPressed: _connecting
                                  ? null
                                  : () => _connect(device)
                                      .then((_) => setSheetState(() {})),
                              child: Text('connect'.tr()),
                            ),
                    ),
                ],
                const SizedBox(height: 16),
                Text(
                  'gridDensity'.tr(namedArgs: {'count': '$_gridSize'}),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Slider(
                  value: _gridSize.toDouble(),
                  min: 2,
                  max: 10,
                  divisions: 8,
                  label: '$_gridSize × $_gridSize',
                  onChanged: (v) => update(() {
                    _gridSize = v.round();
                    if (_corners.length == 4) {
                      _waypoints =
                          generateWaypoints(_corners, gridSize: _gridSize);
                    }
                  }),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('done'.tr()),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showReading(SoilReading reading) {
    final npk = reading.npk;
    _showSheet([
      _SheetSection(title: 'sensorData'.tr(), body: Text(_describe(reading))),
      if (npk == null)
        _SheetSection(
          title: 'predictedData'.tr(),
          body: Text('predictionUnavailable'.tr(
            namedArgs: {'count': '${reading.sensorValues.length}'},
          )),
        )
      else ..._adviceSections(npk, title: 'predictedData'.tr()),
    ]);
  }

  void _showReport() {
    final average = averageNpk(_readings);
    _showSheet([
      Text('finalReport'.tr(), style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 4),
      Text('readingsCount'.tr(namedArgs: {'count': '${_readings.length}'})),
      if (_readings.isEmpty)
        _SheetSection(title: '', body: Text('noReadingsYet'.tr()))
      else if (average == null)
        _SheetSection(
          title: 'averageNpkValues'.tr(),
          body: Text('predictionUnavailable'.tr(
            namedArgs: {'count': '${_readings.first.sensorValues.length}'},
          )),
        )
      else
        ..._adviceSections(average, title: 'averageNpkValues'.tr()),
    ]);
  }

  List<Widget> _adviceSections(List<double> npk, {required String title}) {
    final best = closestProfile(npk);
    return [
      _SheetSection(
        title: title,
        body: Row(
          children: [
            Icon(Icons.circle, size: 12, color: _healthColor(soilHealth(npk))),
            const SizedBox(width: 8),
            Expanded(child: Text(_formatNpk(npk))),
          ],
        ),
      ),
      _SheetSection(
        title: 'suggestedCrops'.tr(),
        body: Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [for (final c in best.crops) Chip(label: Text(c))],
        ),
      ),
      _SheetSection(
        title: 'suggestedNpkFertilizerAmount'.tr(),
        body: Column(
          children: [
            for (final advice in fertilizerAdvice(npk))
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  title: Text(advice.profile.crops.join(', ')),
                  subtitle: Text(
                    'N ${advice.n.toStringAsFixed(1)} · '
                    'P ${advice.p.toStringAsFixed(1)} · '
                    'K ${advice.k.toStringAsFixed(1)} kg/ha',
                  ),
                  trailing: Text('₹${advice.cost.toStringAsFixed(0)}'),
                ),
              ),
          ],
        ),
      ),
    ];
  }

  void _showSheet(List<Widget> children) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: children,
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.text, required this.icon, this.action});

  final String text;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(text),
              ),
            ),
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}

class _SheetSection extends StatelessWidget {
  const _SheetSection({required this.title, required this.body});

  final String title;
  final Widget body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 6),
          ],
          body,
        ],
      ),
    );
  }
}
