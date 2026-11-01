import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Messages the robot sends back over SMS or Bluetooth.
sealed class RobotMessage {
  const RobotMessage();
}

/// `S:Lat:<lat>,Lng:<lng>,Sensor:<pH>-<EC>-<moisture>`
///
/// Sensor values may also be separated by commas or spaces, which is what the
/// Arduino sketch sends (`Sensor: 512, 300`).
class SensorMessage extends RobotMessage {
  const SensorMessage(this.position, this.values);
  final LatLng position;
  final List<double> values;
}

/// `C:Lat:<lat>,Lng:<lng>` - the robot's current position.
class PositionMessage extends RobotMessage {
  const PositionMessage(this.position);
  final LatLng position;
}

/// `D:` - the survey is finished.
class SurveyDoneMessage extends RobotMessage {
  const SurveyDoneMessage();
}

final _lat = RegExp(r'Lat\s*:\s*(-?\d+(?:\.\d+)?)', caseSensitive: false);
final _lng = RegExp(r'Lng\s*:\s*(-?\d+(?:\.\d+)?)', caseSensitive: false);
final _sensor = RegExp(r'Sensor\s*:(.*)$', caseSensitive: false);
// Unsigned on purpose: "6.5-1.2-40" uses '-' as a separator, and soil
// readings are never negative.
final _number = RegExp(r'\d+(?:\.\d+)?');

/// Parses one robot message, or returns `null` if it is malformed. Malformed
/// input used to crash the app with a RangeError.
RobotMessage? parseRobotMessage(String raw) {
  final message = raw.replaceAll(';', '').trim();
  if (message.startsWith('D:')) return const SurveyDoneMessage();
  final isSensor = message.startsWith('S:');
  if (!isSensor && !message.startsWith('C:')) return null;

  final lat = double.tryParse(_lat.firstMatch(message)?.group(1) ?? '');
  final lng = double.tryParse(_lng.firstMatch(message)?.group(1) ?? '');
  if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
    return null;
  }
  final position = LatLng(lat, lng);
  if (!isSensor) return PositionMessage(position);

  final sensorText = _sensor.firstMatch(message)?.group(1) ?? '';
  final values = _number
      .allMatches(sensorText)
      .map((m) => double.parse(m.group(0)!))
      .toList();
  return values.length >= 2 ? SensorMessage(position, values) : null;
}

/// Splits a Bluetooth byte stream buffer into complete `;`-terminated
/// messages. Returns the messages and whatever incomplete tail remains.
(List<String> messages, String rest) splitMessages(String buffer) {
  final parts = buffer.split(';');
  final rest = parts.removeLast();
  return (
    parts.map((p) => p.trim()).where((p) => p.isNotEmpty).toList(),
    rest,
  );
}

/// Encodes waypoints as `GPS: lat,lng; lat,lng; ...` messages that each fit
/// in a single SMS ([maxLength] characters).
List<String> encodeWaypointMessages(
  List<LatLng> waypoints, {
  int maxLength = 160,
}) {
  const prefix = 'GPS: ';
  final messages = <String>[];
  final current = StringBuffer();
  for (final wp in waypoints) {
    // 6 decimals is ~10 cm, plenty for a field robot, and fits more per SMS.
    final text =
        '${wp.latitude.toStringAsFixed(6)},${wp.longitude.toStringAsFixed(6)}';
    final separator = current.isEmpty ? '' : '; ';
    if (current.isNotEmpty &&
        prefix.length + current.length + separator.length + text.length >
            maxLength) {
      messages.add('$prefix$current');
      current.clear();
    }
    if (current.isNotEmpty) current.write('; ');
    current.write(text);
  }
  if (current.isNotEmpty) messages.add('$prefix$current');
  return messages;
}

/// Compares phone numbers by their last 10 digits so "+91 98402 15374" and
/// "9840215374" match.
bool samePhoneNumber(String? a, String? b) {
  String digits(String? s) => (s ?? '').replaceAll(RegExp(r'\D'), '');
  final da = digits(a), db = digits(b);
  if (da.isEmpty || db.isEmpty) return false;
  final n = da.length < 10 || db.length < 10
      ? (da.length < db.length ? da.length : db.length)
      : 10;
  return da.substring(da.length - n) == db.substring(db.length - n);
}
