import 'package:rohd/rohd.dart';

/// A run of equal samples: the first sample index and the sample count.
typedef LedRun = ({int start, int length});

/// Records one pin once per clock, at the falling edge. A sample of -1 means
/// the pin was X or Z.
class LedWave {
  final List<int> samples = [];

  LedWave(Logic clk, Logic pin) {
    clk.negedge.listen((_) {
      final v = pin.value;
      samples.add(v.isValid ? v.toInt() : -1);
    });
  }

  /// Runs of [level] that start after the first sample and end before the
  /// last one, so the idle level before and after a train is not a run.
  List<LedRun> pulses(int level) => ledPulses(samples, level);
}

/// See [LedWave.pulses].
List<LedRun> ledPulses(List<int> samples, int level) {
  final runs = <LedRun>[];
  var i = 0;
  while (i < samples.length) {
    var j = i;
    while (j < samples.length && samples[j] == samples[i]) {
      j++;
    }
    if (samples[i] == level && i > 0 && j < samples.length) {
      runs.add((start: i, length: j - i));
    }
    i = j;
  }
  return runs;
}

/// One frame decoded by [decodeWs2812].
class Ws2812Frame {
  /// Decoded bytes, first bit received is the top bit of the first byte.
  final List<int> bytes;

  /// The high time of every bit, in nanoseconds.
  final List<double> highNs;

  /// The low time after every bit, in nanoseconds. The last one is the gap
  /// that ended the frame.
  final List<double> lowNs;

  Ws2812Frame(this.bytes, this.highNs, this.lowNs);

  /// The gap that ended the frame.
  double get resetNs => lowNs.isEmpty ? 0 : lowNs.last;
}

/// Decodes WS2812 frames from per-clock [samples] at [clkHz]. A bit is 1 when
/// its high time is longer than 0.6 us, and a low longer than 9 us ends a
/// frame. The idle level is low. It throws on an X sample and on a frame
/// that is not a whole number of bytes.
List<Ws2812Frame> decodeWs2812(List<int> samples, int clkHz) {
  if (samples.contains(-1)) {
    throw StateError('decodeWs2812: the samples contain X');
  }
  final nsPerClk = 1e9 / clkHz;
  final frames = <Ws2812Frame>[];
  var highs = <double>[];
  var lows = <double>[];
  void close() {
    if (highs.isEmpty) return;
    if (highs.length % 8 != 0) {
      throw StateError('decodeWs2812: a frame has ${highs.length} bits');
    }
    final bytes = <int>[];
    for (var b = 0; b < highs.length; b += 8) {
      var v = 0;
      for (var k = 0; k < 8; k++) {
        v = (v << 1) | (highs[b + k] > 600 ? 1 : 0);
      }
      bytes.add(v);
    }
    frames.add(Ws2812Frame(bytes, highs, lows));
    highs = <double>[];
    lows = <double>[];
  }

  var i = 0;
  while (i < samples.length && samples[i] != 1) {
    i++;
  }
  while (i < samples.length) {
    var j = i;
    while (j < samples.length && samples[j] == 1) {
      j++;
    }
    highs.add((j - i) * nsPerClk);
    i = j;
    while (j < samples.length && samples[j] != 1) {
      j++;
    }
    final low = (j - i) * nsPerClk;
    lows.add(low);
    i = j;
    if (low > 9000) close();
  }
  close();
  return frames;
}
