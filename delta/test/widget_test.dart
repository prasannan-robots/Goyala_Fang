import 'package:delta/logic/field_geometry.dart';
import 'package:delta/logic/robot_protocol.dart';
import 'package:delta/logic/soil_advisor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

void main() {
  const square = [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0)];

  group('field geometry', () {
    test('point in polygon handles vertical edges and the closing edge', () {
      expect(isPointInPolygon(const LatLng(0.5, 0.5), square), isTrue);
      expect(isPointInPolygon(const LatLng(0.5, 1.5), square), isFalse);
      expect(isPointInPolygon(const LatLng(-0.5, 0.5), square), isFalse);
      // Right next to the closing edge (last vertex -> first).
      expect(isPointInPolygon(const LatLng(0.5, 0.01), square), isTrue);
    });

    test('corners tapped in a crossing order are reordered', () {
      final bowTie = [square[0], square[2], square[1], square[3]];
      final ordered = orderCorners(bowTie);
      expect(generateWaypoints(ordered, gridSize: 4), hasLength(16));
    });

    test('waypoints form a serpentine grid inside the field', () {
      final wps = generateWaypoints(square, gridSize: 3);
      expect(wps, hasLength(9));
      expect(wps.every((p) => isPointInPolygon(p, square)), isTrue);
      // Row 0 goes left->right, row 1 right->left.
      expect(wps[0].longitude < wps[2].longitude, isTrue);
      expect(wps[3].longitude > wps[5].longitude, isTrue);
    });

    test('degenerate field returns no waypoints instead of hanging', () {
      const line = [LatLng(0, 0), LatLng(0, 1), LatLng(0, 2), LatLng(0, 3)];
      expect(generateWaypoints(line), isEmpty);
    });
  });

  group('robot protocol', () {
    test('parses the app format', () {
      final m = parseRobotMessage('S:Lat:12.5,Lng:80.25,Sensor:6.5-1.2-40;');
      expect(m, isA<SensorMessage>());
      final s = m! as SensorMessage;
      expect(s.position, const LatLng(12.5, 80.25));
      expect(s.values, [6.5, 1.2, 40]);
    });

    test('parses what the Arduino sketch actually sends', () {
      final m = parseRobotMessage(
        'S:Lat:12.820030,Lng:80.039433,Sensor: 512, 300\r\n',
      );
      expect((m! as SensorMessage).values, [512, 300]);
    });

    test('parses position and done messages', () {
      expect(parseRobotMessage('C:Lat:1.5,Lng:2.5'), isA<PositionMessage>());
      expect(parseRobotMessage('D:'), isA<SurveyDoneMessage>());
    });

    test('rejects malformed messages instead of crashing', () {
      for (final bad in [
        '',
        'hello',
        'S:',
        'S:Lat:12.5',
        'S:Lat:999,Lng:1,Sensor:1-2-3',
        'S:Lat:1,Lng:1,Sensor:7',
      ]) {
        expect(parseRobotMessage(bad), isNull, reason: bad);
      }
    });

    test('splits a Bluetooth buffer and keeps the partial tail', () {
      final (messages, rest) = splitMessages('C:Lat:1,Lng:2;D:;S:La');
      expect(messages, ['C:Lat:1,Lng:2', 'D:']);
      expect(rest, 'S:La');
    });

    test('waypoint messages each fit in one SMS', () {
      final wps = List.generate(
        40,
        (i) => LatLng(12.123456789 + i / 1e4, 80.123456789 + i / 1e4),
      );
      final messages = encodeWaypointMessages(wps);
      expect(messages.every((m) => m.length <= 160), isTrue);
      expect(messages.every((m) => m.startsWith('GPS: ')), isTrue);
      final sent = messages.expand((m) => m.substring(5).split('; '));
      expect(sent, hasLength(40));
    });

    test('phone numbers match with or without country code', () {
      expect(samePhoneNumber('+919840215374', '98402 15374'), isTrue);
      expect(samePhoneNumber('+919840215374', '9840215375'), isFalse);
      expect(samePhoneNumber(null, '9840215374'), isFalse);
    });
  });

  group('soil advisor', () {
    test('averages only readings that have a prediction', () {
      final readings = [
        const SoilReading(
          position: LatLng(0, 0),
          sensorValues: [6, 1, 40],
          npk: [10, 20, 30],
        ),
        const SoilReading(
          position: LatLng(0, 1),
          sensorValues: [6, 1, 40],
          npk: [20, 30, 40],
        ),
        const SoilReading(position: LatLng(0, 2), sensorValues: [512, 300]),
      ];
      expect(averageNpk(readings), [15, 25, 35]);
      expect(averageNpk(readings.sublist(2)), isNull);
    });

    test('fertilizer advice never goes negative', () {
      final advice = fertilizerAdvice([100, 100, 100]);
      expect(advice.every((a) => a.n == 0 && a.p == 0 && a.k == 0), isTrue);
      expect(advice.every((a) => a.cost == 0), isTrue);
    });

    test('suggests the closest crop profile', () {
      expect(closestProfile([29, 11, 9]).name, 'High nitrogen');
      expect(closestProfile([10, 10, 31]).name, 'High potassium');
    });

    test('two-value readings expose pH and moisture, no EC', () {
      const r = SoilReading(position: LatLng(0, 0), sensorValues: [6.5, 40]);
      expect(r.ph, 6.5);
      expect(r.ec, isNull);
      expect(r.moisture, 40);
    });
  });
}
