import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  for (final name in ['kc705', 'ulx3s-85f']) {
    test('$name has 8 plain LEDs on led[0] to led[7]', () {
      final board = HarborBoard.get(name);
      expect(board.ledChannels, hasLength(1));
      final ch = board.ledChannels.single;
      expect(ch.config.kind, equals(HarborLedKind.pwm));
      expect(ch.config.activeLow, isFalse);
      expect(ch.pins, equals([for (var i = 0; i < 8; i++) 'led[$i]']));
      expect(ch.config.pwmPins, hasLength(8));
      for (var i = 0; i < 8; i++) {
        expect(ch.config.pwmPins[i].pixel, equals(i));
        expect(ch.config.pwmPins[i].byte, equals(HarborLedByte.b));
      }
      expect(ch.pixels, equals(8));
    });
  }

  test('arty-s7-50 has 4 plain LEDs and 2 RGB LEDs', () {
    final board = HarborBoard.get('arty-s7-50');
    final ch = board.ledChannels.single;
    expect(ch.config.activeLow, isFalse);
    expect(ch.config.pwmPins, hasLength(10));
    expect(ch.pins, hasLength(10));
    expect(ch.pixels, equals(6));
    for (var i = 0; i < 4; i++) {
      expect(ch.config.pwmPins[i].pixel, equals(i));
      expect(ch.config.pwmPins[i].byte, equals(HarborLedByte.b));
    }
    const rgb = [HarborLedByte.r, HarborLedByte.g, HarborLedByte.b];
    for (var i = 0; i < 6; i++) {
      expect(ch.config.pwmPins[4 + i].pixel, equals(4 + i ~/ 3));
      expect(ch.config.pwmPins[4 + i].byte, equals(rgb[i % 3]));
    }
  });

  test('the arty-s7-50 LED sites are from the Digilent XDC', () {
    final pins = HarborBoard.get('arty-s7-50').pins;
    expect(pins['led[0]'], equals('E18 LVCMOS33'));
    expect(pins['led[1]'], equals('F13 LVCMOS33'));
    expect(pins['led[2]'], equals('E13 LVCMOS33'));
    expect(pins['led[3]'], equals('H15 LVCMOS33'));
    expect(pins['led0_r'], equals('J15 LVCMOS33'));
    expect(pins['led0_g'], equals('G17 LVCMOS33'));
    expect(pins['led0_b'], equals('F15 LVCMOS33'));
    expect(pins['led1_r'], equals('E15 LVCMOS33'));
    expect(pins['led1_g'], equals('F18 LVCMOS33'));
    expect(pins['led1_b'], equals('E14 LVCMOS33'));
  });

  test('every LED pin of a preset is in its pin catalog, once', () {
    for (final board in HarborBoard.byName.values) {
      final balls = <String>{};
      for (final e in board.pins.entries) {
        final ball = e.value.split(' ').first;
        if (e.key.startsWith('led')) {
          expect(balls.add(ball), isTrue, reason: '${board.name} ${e.key}');
        }
      }
      for (final ch in board.ledChannels) {
        expect(ch.pins, hasLength(ch.config.pwmPins.length));
        for (final pin in ch.pins) {
          expect(board.pins.containsKey(pin), isTrue, reason: pin);
        }
      }
    }
  });

  test('the Arty ball of an LED is used by no other pin', () {
    final board = HarborBoard.get('arty-s7-50');
    final byBall = <String, List<String>>{};
    for (final e in board.pins.entries) {
      byBall.putIfAbsent(e.value.split(' ').first, () => []).add(e.key);
    }
    expect(byBall.values.where((v) => v.length > 1), isEmpty);
  });

  test('each preset builds an engine', () async {
    for (final board in HarborBoard.byName.values) {
      for (final ch in board.ledChannels) {
        final led = HarborLedEngine(
          baseAddress: 0x10005000,
          channels: [ch.config],
          maxPixels: ch.pixels,
        );
        expect(led.channelOut(0), hasLength(ch.pins.length));
      }
    }
  });

  test('a speed grade copy keeps the led channels', () {
    final preset = HarborBoard.get('ulx3s-85f');
    final graded = HarborBoard.get('ulx3s-85f:8');
    expect(graded.ledChannels, equals(preset.ledChannels));
    expect(graded.ledChannels, isNotEmpty);
  });
}
