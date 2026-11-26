import 'package:rohd/rohd.dart';

/// The kind of output stage of one channel.
enum HarborLedKind { serial, pwm }

/// A byte of a pixel word.
enum HarborLedByte { r, g, b, w }

/// One PWM pin: the pixel and the byte that set its duty.
class HarborLedPin {
  final int pixel;
  final HarborLedByte byte;

  /// The highest duty that software may set on this pixel. The driver
  /// reports it as the brightness ceiling. A pixel with several pins uses
  /// the lowest value of its pins.
  final int maxDuty;
  const HarborLedPin(this.pixel, this.byte, {this.maxDuty = 255});
}

/// The configuration of one LED channel.
class HarborLedChannelConfig {
  final HarborLedKind kind;

  /// The pins of a PWM channel. Empty for a serial channel.
  final List<HarborLedPin> pwmPins;

  /// The reset value of the POLARITY bit.
  final bool activeLow;

  const HarborLedChannelConfig.serial({this.activeLow = false})
    : kind = HarborLedKind.serial,
      pwmPins = const [];

  const HarborLedChannelConfig.pwm(this.pwmPins, {this.activeLow = false})
    : kind = HarborLedKind.pwm;

  /// The number of pixels that the pin map reads, 0 for a serial channel.
  int get pixelsUsed =>
      pwmPins.fold(0, (n, p) => p.pixel + 1 > n ? p.pixel + 1 : n);
}

/// A source of LED output channels that a board binds to its LED pins.
abstract interface class HarborLedDriver {
  /// The number of channels.
  int get channelCount;

  /// The output bits of channel [k], in the order of the pin map.
  List<Logic> channelOut(int k);
}
