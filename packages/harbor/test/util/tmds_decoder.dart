import '../video/tmds_reference.dart';

/// A model of an HDMI 1.4 or DVI sink. [decodeTmds] takes the 10-bit
/// symbols of channels 0, 1 and 2, one entry for each pixel clock, and
/// gives the periods, video lines and packets. Each error has its clock.
///
/// The model starts at the first control clock. A period that the end of
/// the stream cuts is not an error.

/// Kinds of [TmdsPeriod].
enum TmdsPeriodKind {
  control,
  videoPreamble,
  islandPreamble,
  videoGuard,
  video,
  islandGuard,
  island,
}

/// A run of clocks of one kind.
class TmdsPeriod {
  final TmdsPeriodKind kind;
  final int start;
  final int length;
  const TmdsPeriod(this.kind, this.start, this.length);

  @override
  String toString() => '${kind.name}@$start+$length';
}

/// The pixels of one video period, each `r << 16 | g << 8 | b`.
class TmdsVideo {
  final int start;
  final List<int> pixels;

  /// The period has a preamble and a guard band.
  final bool guarded;
  const TmdsVideo(this.start, this.pixels, {required this.guarded});
}

/// One data island packet. [header] is HB2..HB0 (HB0 in bits 7..0), each
/// of [subpackets] holds bytes 6..0 (byte 0 in bits 7..0). The BCH bytes
/// are checked and not kept.
class HdmiPacket {
  final int start;
  final int header;
  final List<int> subpackets;
  const HdmiPacket(this.start, this.header, this.subpackets);

  int get type => header & 0xFF;

  @override
  String toString() =>
      'packet@$start ${header.toRadixString(16)} '
      '${subpackets.map((s) => s.toRadixString(16)).join(' ')}';
}

/// The result of [decodeTmds].
class TmdsDecode {
  final periods = <TmdsPeriod>[];
  final video = <TmdsVideo>[];
  final packets = <HdmiPacket>[];

  /// HSYNC in bit 0 and VSYNC in bit 1 for each clock, -1 in a video guard
  /// band or video period and before the first control clock.
  final List<int> sync;
  final errors = <String>[];
  TmdsDecode(int clocks) : sync = List.filled(clocks, -1);
}

const _ctrl = {0x354: 0, 0x0AB: 1, 0x154: 2, 0x2AB: 3};

/// TERC4 symbols (HDMI 1.4 section 5.4.3).
const terc4Symbols = [
  0x29C, 0x263, 0x2E4, 0x2E2, 0x171, 0x11E, 0x18E, 0x13C, //
  0x2CC, 0x139, 0x19C, 0x2C6, 0x28E, 0x271, 0x163, 0x2C3,
];

/// Guard band symbols (HDMI 1.4 sections 5.2.2.1 and 5.2.3.3).
const videoGuard02 = 0x2CC;
const guard1 = 0x133;

/// BCH parity of the low [bits] bits of [value], sent low bit first.
/// Generator x^8 + x^7 + x^6 + 1 (HDMI 1.4 section 5.2.3.5).
int hdmiBch(int value, int bits) {
  var r = 0;
  for (var i = 0; i < bits; i++) {
    final f = (r ^ (value >> i)) & 1;
    r >>= 1;
    if (f == 1) r ^= 0x83;
  }
  return r;
}

/// The 8-bit value of a DVI data symbol.
int tmdsDataValue(int q) {
  final low = (q >> 9) & 1 == 1 ? (~q & 0xFF) : q & 0xFF;
  final xor = (q >> 8) & 1 == 1;
  var d = low & 1;
  for (var i = 1; i < 8; i++) {
    var b = ((low >> i) ^ (low >> (i - 1))) & 1;
    if (!xor) b ^= 1;
    d |= b << i;
  }
  return d;
}

/// Decodes the symbol streams. With [hdmi] false the sink is DVI: video has
/// no preamble and every CTL bit is 0.
TmdsDecode decodeTmds(
  List<int> ch0,
  List<int> ch1,
  List<int> ch2, {
  bool hdmi = true,
}) {
  final n = ch0.length;
  final d = TmdsDecode(n);
  if (ch1.length != n || ch2.length != n) {
    d.errors.add('channel lengths ${ch0.length} ${ch1.length} ${ch2.length}');
    return d;
  }
  bool isCtrl(int i) =>
      _ctrl.containsKey(ch0[i]) &&
      _ctrl.containsKey(ch1[i]) &&
      _ctrl.containsKey(ch2[i]);
  int ctl(int i) => _ctrl[ch1[i]]! | (_ctrl[ch2[i]]! << 2);
  int terc4(int q, int i, String ch) {
    final v = terc4Symbols.indexOf(q);
    if (v < 0) d.errors.add('$i: $ch symbol ${q.toRadixString(16)} not TERC4');
    return v < 0 ? 0 : v;
  }

  void period(TmdsPeriodKind k, int start, int len) {
    if (len > 0) d.periods.add(TmdsPeriod(k, start, len));
  }

  var i = 0;
  while (i < n && !isCtrl(i)) {
    i++;
  }
  final first = i;
  while (i < n) {
    // A control period, with the preamble at its end.
    final cStart = i;
    while (i < n && isCtrl(i)) {
      d.sync[i] = _ctrl[ch0[i]]!;
      final c = ctl(i);
      if (c != 0 && (!hdmi || (c != 1 && c != 5))) {
        d.errors.add('$i: CTL3..0 ${c.toRadixString(2)}');
      }
      i++;
    }
    final cLen = i - cStart;
    if (i >= n) {
      period(TmdsPeriodKind.control, cStart, cLen);
      break;
    }
    var pre = 0;
    var kind = ctl(i - 1);
    while (pre < cLen && ctl(i - 1 - pre) == kind) {
      pre++;
    }
    if (kind == 0) pre = 0;
    if (pre != 0 && pre != 8) {
      d.errors.add('${i - pre}: preamble of $pre clocks');
    }
    period(TmdsPeriodKind.control, cStart, cLen - pre);
    if (pre != 0) {
      period(
        kind == 1
            ? TmdsPeriodKind.videoPreamble
            : TmdsPeriodKind.islandPreamble,
        i - pre,
        pre,
      );
    }
    if (hdmi && cLen < 12 && cStart != first) {
      d.errors.add('$i: control period of $cLen clocks before a period');
    }
    if (pre == 0) kind = 0;

    if (kind == 5) {
      // Data island: guard band, packets, guard band.
      final iStart = i;
      for (var g = 0; g < 2 && i < n; g++, i++) {
        final v = terc4(ch0[i], i, 'ch0');
        d.sync[i] = v & 3;
        if (ch1[i] != guard1 || ch2[i] != guard1 || v >> 2 != 3) {
          d.errors.add('$i: leading guard band');
        }
      }
      period(TmdsPeriodKind.islandGuard, iStart, i - iStart);
      final pStart = i;
      var count = 0;
      while (i < n && ch1[i] != guard1 && !isCtrl(i)) {
        if (i + 32 > n) {
          i = n;
          break;
        }
        var hb = 0;
        final sb = List.filled(4, 0);
        for (var k = 0; k < 32; k++) {
          final j = i + k;
          final v0 = terc4(ch0[j], j, 'ch0');
          final v1 = terc4(ch1[j], j, 'ch1');
          final v2 = terc4(ch2[j], j, 'ch2');
          d.sync[j] = v0 & 3;
          final framing = (v0 >> 3) & 1;
          final want = count == 0 && k == 0 ? 0 : 1;
          if (framing != want) {
            d.errors.add('$j: ch0 bit 3 is $framing');
          }
          hb |= ((v0 >> 2) & 1) << k;
          for (var s = 0; s < 4; s++) {
            sb[s] |= ((v1 >> s) & 1) << (2 * k);
            sb[s] |= ((v2 >> s) & 1) << (2 * k + 1);
          }
        }
        final header = hb & 0xFFFFFF;
        if (hdmiBch(header, 24) != (hb >> 24) & 0xFF) {
          d.errors.add('$i: header BCH');
        }
        final subs = <int>[];
        for (var s = 0; s < 4; s++) {
          final body = sb[s] & 0xFFFFFFFFFFFFFF;
          if (hdmiBch(body, 56) != (sb[s] >>> 56) & 0xFF) {
            d.errors.add('$i: subpacket $s BCH');
          }
          subs.add(body);
        }
        d.packets.add(HdmiPacket(i, header, subs));
        count++;
        i += 32;
      }
      period(TmdsPeriodKind.island, pStart, i - pStart);
      if (i >= n) break;
      if (count == 0 || count > 18) {
        d.errors.add('$pStart: island of $count packets');
      }
      final tStart = i;
      for (var g = 0; g < 2 && i < n; g++, i++) {
        final v = terc4(ch0[i], i, 'ch0');
        d.sync[i] = v & 3;
        if (ch1[i] != guard1 || ch2[i] != guard1 || v >> 2 != 3) {
          d.errors.add('$i: trailing guard band');
        }
      }
      period(TmdsPeriodKind.islandGuard, tStart, i - tStart);
      if (i < n && !isCtrl(i)) {
        d.errors.add('$i: no control after the island');
        while (i < n && !isCtrl(i)) {
          i++;
        }
      }
      continue;
    }

    // Video, with a guard band after a video preamble.
    final guarded = kind == 1;
    if (guarded) {
      final gStart = i;
      for (var g = 0; g < 2 && i < n; g++, i++) {
        if (ch0[i] != videoGuard02 ||
            ch1[i] != guard1 ||
            ch2[i] != videoGuard02) {
          d.errors.add('$i: video guard band');
        }
      }
      period(TmdsPeriodKind.videoGuard, gStart, i - gStart);
    } else if (hdmi) {
      d.errors.add('$i: video without a preamble');
    }
    final vStart = i;
    final refs = [TmdsReference(), TmdsReference(), TmdsReference()];
    final pixels = <int>[];
    while (i < n && !isCtrl(i)) {
      final b = tmdsDataValue(ch0[i]);
      final g = tmdsDataValue(ch1[i]);
      final r = tmdsDataValue(ch2[i]);
      for (final (c, q, v) in [
        (0, ch0[i], b),
        (1, ch1[i], g),
        (2, ch2[i], r),
      ]) {
        if (refs[c].encode(de: true, data: v, ctrl: 0) != q) {
          d.errors.add('$i: ch$c symbol ${q.toRadixString(16)} not DVI data');
        }
      }
      pixels.add(r << 16 | g << 8 | b);
      i++;
    }
    period(TmdsPeriodKind.video, vStart, i - vStart);
    d.video.add(TmdsVideo(vStart, pixels, guarded: guarded));
  }
  return d;
}
