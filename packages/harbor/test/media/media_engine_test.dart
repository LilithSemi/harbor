import 'dart:async';
import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../util/reg_bus.dart';

// Reference transform, mirroring the integer arithmetic in media_engine.dart.
// Transform types: 0 = DCT, 1 = ADST, 2 = FLIPADST, 3 = IDTX.
List<List<int>> _dctM(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        ((k == 0 ? sqrt(1 / n) : sqrt(2 / n)) *
                cos((2 * i + 1) * k * pi / (2 * n)) *
                4096)
            .round(),
    ],
];
List<List<int>> _adstM(int n) => [
  for (var k = 0; k < n; k++)
    [
      for (var i = 0; i < n; i++)
        (sqrt(4 / (2 * n + 1)) *
                sin(pi * (2 * i + 1) * (k + 1) / (2 * n + 1)) *
                4096)
            .round(),
    ],
];
List<List<int>> _tr(List<List<int>> m) => [
  for (var i = 0; i < m.length; i++)
    [for (var j = 0; j < m.length; j++) m[j][i]],
];

int _rs(int v) => (v + 2048) >> 12;

// 1D transform of a length-n vector with the given type and direction.
List<int> _t1d(List<int> v, int n, int type, int dir) {
  if (type == 3) {
    final s = n == 8 ? 8192 : 5793; // IDTX scale
    return [for (var k = 0; k < n; k++) _rs(v[k] * s)];
  }
  final adst = type == 1 || type == 2;
  final m = adst
      ? (dir == 1 ? _tr(_adstM(n)) : _adstM(n))
      : (dir == 1 ? _tr(_dctM(n)) : _dctM(n));
  final mat = [
    for (var k = 0; k < n; k++)
      _rs([for (var i = 0; i < n; i++) v[i] * m[k][i]].reduce((a, b) => a + b)),
  ];
  if (type == 2) return [for (var k = 0; k < n; k++) mat[n - 1 - k]]; // FLIP
  return mat;
}

// Separable 2D transform: rows use hType, columns use vType. Returns an n*n
// row-major block.
List<int> _xform2d(List<int> x, int n, int hType, int vType, int dir) {
  final a = List.filled(n * n, 0);
  for (var r = 0; r < n; r++) {
    final out = _t1d([for (var i = 0; i < n; i++) x[r * n + i]], n, hType, dir);
    for (var k = 0; k < n; k++) {
      a[r * n + k] = out[k];
    }
  }
  final y = List.filled(n * n, 0);
  for (var c = 0; c < n; c++) {
    final out = _t1d([for (var i = 0; i < n; i++) a[i * n + c]], n, vType, dir);
    for (var l = 0; l < n; l++) {
      y[l * n + c] = out[l];
    }
  }
  return y;
}

// Dequantizes coefficients before an inverse transform (DC = position 0).
List<int> _dequant(List<int> coeffs, int qp) {
  int s16(int v) {
    v &= 0xFFFF;
    return v >= 0x8000 ? v - 0x10000 : v;
  }

  final dcQ = qp * 2 + 4;
  final acQ = qp * 4 + 8;
  return [
    for (var i = 0; i < coeffs.length; i++)
      s16(coeffs[i] * (i == 0 ? dcQ : acQ)),
  ];
}

// Reference range decoder with adaptive CDF, mirroring HarborEntropyDecoder.
class _Range {
  int rng = 0xFFFF;
  int code = 0;
  final List<int> bits;
  int pos = 16;
  _Range(this.bits) {
    for (var i = 0; i < 16; i++) {
      code = (code << 1) | bits[i];
    }
  }
  int _next() => pos < bits.length ? bits[pos++] : 0;
  int decode(List<int> cdf, int n) {
    final b = [for (var s = 0; s < n; s++) (rng * cdf[s]) >> 15];
    var s = 0;
    while (s < n - 1 && code >= b[s]) {
      s++;
    }
    final lo = s == 0 ? 0 : b[s - 1];
    code -= lo;
    rng = b[s] - lo;
    while (rng < 0x8000) {
      rng = rng << 1;
      code = (code << 1) | _next();
    }
    return s;
  }
}

class _Ctx {
  final List<int> cdf;
  final int n;
  int count = 0;
  _Ctx(this.cdf, this.n);
  void adapt(int val) {
    final speed = n < 2 ? 0 : (n < 4 ? 1 : 2);
    final rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + speed;
    for (var i = 0; i < n - 1; i++) {
      if (i < val) {
        cdf[i] -= cdf[i] >> rate;
      } else {
        cdf[i] += (0x8000 - cdf[i]) >> rate;
      }
    }
    if (count < 32) count++;
  }
}

List<_Ctx> _freshCtxs() => [
  _Ctx([for (var i = 0; i < 16; i++) (i + 1) * 2048], 16),
  _Ctx([16384, 24576, 30720, 32768], 4),
  _Ctx([8192, 16384, 24576, 32768], 4),
  _Ctx([16384, 32768], 2),
];

// Reference coefficient-syntax decode over a persistent range + contexts, so
// successive blocks share adapting CDFs and a continuing stream window.
List<int> _decodeBlockWith(_Range range, List<_Ctx> ctxs, int numCoeffs) {
  int dec(int c) {
    final s = range.decode(ctxs[c].cdf, ctxs[c].n);
    ctxs[c].adapt(s);
    return s;
  }

  var eob = dec(0);
  if (eob > numCoeffs) eob = numCoeffs;
  final coeffs = List.filled(numCoeffs, 0);
  var pos = 0;
  while (pos < eob) {
    final base = dec(1);
    if (base == 0) {
      pos++;
      continue;
    }
    var level = base;
    if (base == 3) {
      var brCnt = 0;
      while (true) {
        final r = dec(2);
        level += r;
        if (r < 3 || brCnt == 3) break;
        brCnt++;
      }
    }
    final sign = dec(3);
    coeffs[pos] = (sign & 1) != 0 ? -level : level;
    pos++;
  }
  return coeffs;
}

// Single-block convenience wrapper.
List<int> _decodeBlock(List<int> bits, int numCoeffs) =>
    _decodeBlockWith(_Range(bits), _freshCtxs(), numCoeffs);

class _OdEc {
  static const w = 32;
  static const mask = (1 << w) - 1;
  int dif = 0, rng = 0x8000, cnt = -15;
  final List<int> buf;
  int bptr = 0;
  _OdEc(this.buf) {
    dif = (1 << (w - 1)) - 1;
    _refill();
  }
  void _refill() {
    var s = 8 - cnt, p = 0;
    while (s >= 0 && p < 3) {
      final byte = bptr < buf.length ? buf[bptr] : 0;
      dif = (dif ^ (byte << s)) & mask;
      cnt += 8;
      s -= 8;
      p++;
      bptr++;
    }
  }

  int _ilog(int x) {
    var n = 0;
    while (x > 0) {
      n++;
      x >>= 1;
    }
    return n;
  }

  int decode(List<int> icdf, int nsyms) {
    final c = dif >> (w - 16);
    var v = rng, ret = -1, u = rng;
    do {
      u = v;
      ret++;
      v = ((rng >> 8) * (icdf[ret] >> 6)) >> 1;
      v += 4 * (nsyms - 1 - ret);
    } while (c < v);
    final r = u - v;
    dif = (dif - (v << (w - 16))) & mask;
    final d = 16 - _ilog(r);
    cnt -= d;
    dif = (((dif + 1) << d) - 1) & mask;
    rng = r << d;
    if (cnt < 0) _refill();
    return ret;
  }
}

class _ICtx {
  final List<int> icdf;
  final int nsyms;
  int count = 0;
  _ICtx(this.icdf, this.nsyms);
  void adapt(int sym) {
    final speed = nsyms < 2 ? 0 : (nsyms < 4 ? 1 : 2);
    final rate = 3 + (count > 15 ? 1 : 0) + (count > 31 ? 1 : 0) + speed;
    for (var i = 0; i < nsyms - 1; i++) {
      final toward = i < sym ? 32768 : 0;
      if (icdf[i] <= toward) {
        icdf[i] += (toward - icdf[i]) >> rate;
      } else {
        icdf[i] -= (icdf[i] - toward) >> rate;
      }
    }
    if (count < 32) count++;
  }
}

List<_ICtx> _freshOdEcCtxs() => [
  _ICtx([for (var i = 0; i < 16; i++) (15 - i) * 2048], 16),
  _ICtx([16384, 8192, 2048, 0], 4),
  _ICtx([24576, 16384, 8192, 0], 4),
  _ICtx([16384, 0], 2),
];

// Coefficient-syntax decode over a persistent od_ec window + contexts (so a
// grid of blocks shares one continuing stream and adapting CDFs).
List<int> _decodeBlockOdEcWith(_OdEc od, List<_ICtx> ctxs, int numCoeffs) {
  int dec(int c) {
    final s = od.decode(ctxs[c].icdf, ctxs[c].nsyms);
    ctxs[c].adapt(s);
    return s;
  }

  var eob = dec(0);
  if (eob > numCoeffs) eob = numCoeffs;
  final coeffs = List.filled(numCoeffs, 0);
  var pos = 0;
  while (pos < eob) {
    final base = dec(1);
    if (base == 0) {
      pos++;
      continue;
    }
    var level = base;
    if (base == 3) {
      var brCnt = 0;
      while (true) {
        final r = dec(2);
        level += r;
        if (r < 3 || brCnt == 3) break;
        brCnt++;
      }
    }
    final sign = dec(3);
    coeffs[pos] = (sign & 1) != 0 ? -level : level;
    pos++;
  }
  return coeffs;
}

// Single-block od_ec convenience wrapper.
List<int> _decodeBlockOdEc(List<int> buf, int numCoeffs) =>
    _decodeBlockOdEcWith(_OdEc(buf), _freshOdEcCtxs(), numCoeffs);

// Packs 16 stream bytes into a 128-bit beat, MSB byte first.
BigInt _packBeat(List<int> bytes, int off) {
  var v = BigInt.zero;
  for (var b = 0; b < 16; b++) {
    final byte = off + b < bytes.length ? bytes[off + b] : 0;
    v |= BigInt.from(byte & 0xFF) << ((15 - b) * 8);
  }
  return v;
}

// Packs 8 signed 16-bit samples into a 128-bit word, LSB first.
BigInt _pack(List<int> s) {
  var v = BigInt.zero;
  for (var j = 0; j < 8; j++) {
    v |= BigInt.from(s[j] & 0xFFFF) << (j * 16);
  }
  return v;
}

void main() {
  // The rest of this file drives the register bus directly over Wishbone and
  // runs full codec-pipeline simulations, so it stays on the default kind to
  // keep the suite's run time in check. This group alone runs register
  // access over every fabric kind, including the required sel-0 check.
  for (final kind in HarborFabricKind.values) {
    _registerBusTests(kind);
  }

  group('HarborCodecFormat', () {
    test('video codecs are video', () {
      expect(HarborCodecFormat.h264.isVideo, isTrue);
      expect(HarborCodecFormat.h265.isVideo, isTrue);
      expect(HarborCodecFormat.vp9.isVideo, isTrue);
      expect(HarborCodecFormat.av1.isVideo, isTrue);
    });

    test('image codecs are not video', () {
      expect(HarborCodecFormat.jpeg.isVideo, isFalse);
      expect(HarborCodecFormat.jpeg2000.isVideo, isFalse);
    });

    test('all codecs are image', () {
      for (final fmt in HarborCodecFormat.values) {
        expect(fmt.isImage, isTrue);
      }
    });

    test('display names', () {
      expect(HarborCodecFormat.h264.displayName, equals('H.264/AVC'));
      expect(HarborCodecFormat.av1.displayName, equals('AV1'));
    });
  });

  group('HarborCodecInstance', () {
    test('decode only', () {
      const inst = HarborCodecInstance(
        format: HarborCodecFormat.h264,
        capability: HarborCodecCapability.decodeOnly,
      );
      expect(inst.canDecode, isTrue);
      expect(inst.canEncode, isFalse);
    });

    test('both encode and decode', () {
      const inst = HarborCodecInstance(
        format: HarborCodecFormat.h265,
        capability: HarborCodecCapability.both,
      );
      expect(inst.canDecode, isTrue);
      expect(inst.canEncode, isTrue);
    });

    test('4K support', () {
      const inst4k = HarborCodecInstance(
        format: HarborCodecFormat.av1,
        capability: HarborCodecCapability.decodeOnly,
        maxWidth: 3840,
        maxHeight: 2160,
      );
      expect(inst4k.supports4K, isTrue);
      expect(inst4k.supports8K, isFalse);
    });

    test('8K support', () {
      const inst8k = HarborCodecInstance(
        format: HarborCodecFormat.av1,
        capability: HarborCodecCapability.decodeOnly,
        maxWidth: 7680,
        maxHeight: 4320,
      );
      expect(inst8k.supports4K, isTrue);
      expect(inst8k.supports8K, isTrue);
    });

    test('bit depths', () {
      const inst = HarborCodecInstance(
        format: HarborCodecFormat.h265,
        capability: HarborCodecCapability.both,
        bitDepths: [8, 10, 12],
      );
      expect(inst.bitDepths, containsAll([8, 10, 12]));
    });
  });

  group('HarborMediaEngine', () {
    test('creates with codec list', () {
      final engine = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.h264,
            capability: HarborCodecCapability.both,
          ),
          HarborCodecInstance(
            format: HarborCodecFormat.h265,
            capability: HarborCodecCapability.decodeOnly,
          ),
          HarborCodecInstance(
            format: HarborCodecFormat.jpeg,
            capability: HarborCodecCapability.both,
          ),
        ],
      );
      expect(engine.codecs, hasLength(3));
      expect(engine.maxSessions, equals(4));
      expect(engine.interrupt.width, equals(1));
    });

    test('codec capability queries', () {
      final engine = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.h264,
            capability: HarborCodecCapability.both,
          ),
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
      );

      expect(engine.supportsCodec(HarborCodecFormat.h264), isTrue);
      expect(engine.supportsCodec(HarborCodecFormat.vp9), isFalse);

      expect(engine.canDecode(HarborCodecFormat.h264), isTrue);
      expect(engine.canEncode(HarborCodecFormat.h264), isTrue);
      expect(engine.canDecode(HarborCodecFormat.av1), isTrue);
      expect(engine.canEncode(HarborCodecFormat.av1), isFalse);
    });

    test('decodable and encodable format lists', () {
      final engine = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.h264,
            capability: HarborCodecCapability.both,
          ),
          HarborCodecInstance(
            format: HarborCodecFormat.h265,
            capability: HarborCodecCapability.decodeOnly,
          ),
          HarborCodecInstance(
            format: HarborCodecFormat.jpeg,
            capability: HarborCodecCapability.encodeOnly,
          ),
        ],
      );

      expect(
        engine.decodableFormats,
        containsAll([HarborCodecFormat.h264, HarborCodecFormat.h265]),
      );
      expect(
        engine.encodableFormats,
        containsAll([HarborCodecFormat.h264, HarborCodecFormat.jpeg]),
      );
    });

    test('DT node', () {
      final engine = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.h264,
            capability: HarborCodecCapability.both,
            maxWidth: 3840,
            maxHeight: 2160,
          ),
        ],
        maxSessions: 8,
      );
      final dt = engine.dtNode;
      expect(dt.compatible.first, equals('harbor,media-engine'));
      expect(dt.reg.start, equals(0x20000000));
      expect(dt.properties['max-sessions'], equals(8));
      expect(dt.properties['harbor,max-width'], equals(3840));
      expect(dt.properties['harbor,max-height'], equals(2160));
    });

    test('DMA interface widths', () {
      final engine = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.h264,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
        dmaAddrWidth: 40,
      );
      expect(engine.dmaReadAddr.width, equals(40));
      expect(engine.dmaWriteAddr.width, equals(40));
      expect(engine.dmaReadData.width, equals(128));
      expect(engine.dmaWriteData.width, equals(128));
    });

    test('two parameter sets give different definitionNames', () {
      const codec = [
        HarborCodecInstance(
          format: HarborCodecFormat.h264,
          capability: HarborCodecCapability.both,
        ),
      ];
      final a = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: codec,
        maxSessions: 4,
      );
      final b = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: codec,
        maxSessions: 8,
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
    });
  });

  group('HarborMediaPixelFormat', () {
    test('all formats defined', () {
      expect(HarborMediaPixelFormat.values, hasLength(7));
      expect(HarborMediaPixelFormat.nv12.name, equals('nv12'));
      expect(HarborMediaPixelFormat.p010.name, equals('p010'));
    });
  });

  group('HarborRateControlMode', () {
    test('all modes defined', () {
      expect(HarborRateControlMode.values, hasLength(4));
      expect(HarborRateControlMode.cqp.name, equals('cqp'));
      expect(HarborRateControlMode.cbr.name, equals('cbr'));
      expect(HarborRateControlMode.vbr.name, equals('vbr'));
      expect(HarborRateControlMode.crf.name, equals('crf'));
    });
  });

  group('HarborMediaEngine transform', () {
    // Global register BYTE offsets.
    const engCtrl = 0x00;
    const intStatus = 0x20;
    // Session 0 registers: the session block is byte 0x100 + N*0x100, and each
    // register is its own 8-byte slot.
    const s0Base = 0x100;
    const s0Ctrl = s0Base + 0x00;
    const s0Src = s0Base + 0x10;
    const s0Dst = s0Base + 0x20;
    const s0Qp = s0Base + 0x50;
    const dstWord = 8; // dst byte 0x80

    late HarborMediaEngine eng;
    late Logic clk, reset, stb, we, adr, mosi;
    late List<Logic> mem;
    late int blockN;

    Future<void> bw(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (eng.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      stb.inject(0);
      we.inject(0);
      await clk.nextPosedge;
    }

    Future<int> br(int addr) async {
      adr.inject(addr);
      we.inject(0);
      stb.inject(1);
      await clk.nextPosedge;
      while (eng.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = eng.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut(List<int> input) async {
      blockN = sqrt(input.length).round(); // 4 or 8
      final beats = input.length ~/ 8; // 128-bit words of input
      eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      // 128-bit DMA memory model (16 words): ack=req single cycle,
      // combinational read, clocked write. Input preset at words 0..beats-1.
      mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            for (var i = 0; i < 16; i++)
              mem[i] <
                  Const(
                    i < beats
                        ? _pack(input.sublist(i * 8, i * 8 + 8))
                        : BigInt.zero,
                    width: 128,
                  ),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(10000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    // Reads back the result block (n*n samples, row-major) from the dst words.
    List<int> result() {
      final out = <int>[];
      final beats = blockN * blockN ~/ 8;
      for (var b = 0; b < beats; b++) {
        final v = mem[dstWord + b].value.toBigInt();
        for (var j = 0; j < 8; j++) {
          out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
        }
      }
      return out;
    }

    Future<void> runBlock(
      int dir, {
      int size = 0,
      int hType = 0,
      int vType = 0,
      int qp = 0,
      bool deq = false,
    }) async {
      await bw(engCtrl, 0x1); // enable
      await bw(s0Src, 0x00);
      await bw(s0Dst, dstWord * 16);
      if (deq) await bw(s0Qp, qp); // SESS_QP
      // SESS_CTRL: start | dir<<1 | size<<2 | deq<<3 | hType<<8 | vType<<10
      await bw(
        s0Ctrl,
        0x1 |
            (dir << 1) |
            (size << 2) |
            ((deq ? 1 : 0) << 3) |
            (hType << 8) |
            (vType << 10),
      );
      for (var i = 0; i < 400; i++) {
        if ((await br(intStatus)) & 0x1 == 0x1) break;
      }
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test('4x4 forward DCT matches the integer reference', () async {
      final input = [for (var i = 0; i < 16; i++) i * 13 - 40];
      await setUpDut(input);
      await runBlock(0);
      final expected = [
        for (final y in _xform2d(input, 4, 0, 0, 0)) y & 0xFFFF,
      ];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('4x4 inverse IDCT matches the integer reference', () async {
      final input = [for (var i = 0; i < 16; i++) (i % 5) * 30 - 60];
      await setUpDut(input);
      await runBlock(1);
      final expected = [
        for (final y in _xform2d(input, 4, 0, 0, 1)) y & 0xFFFF,
      ];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('done sets the session interrupt', () async {
      final input = [for (var i = 0; i < 16; i++) i];
      await setUpDut(input);
      await runBlock(0);
      expect((await br(intStatus)) & 0x1, equals(0x1));
      await Simulator.endSimulation();
    });

    // 4x4 mixed transforms across all four 1D types per direction.
    for (final tx in [
      ('ADST_DCT', 1, 0),
      ('DCT_ADST', 0, 1),
      ('ADST_ADST', 1, 1),
      ('FLIPADST_DCT', 2, 0),
      ('DCT_FLIPADST', 0, 2),
      ('IDTX_DCT', 3, 0),
      ('IDTX_IDTX', 3, 3),
      ('ADST_FLIPADST', 1, 2),
    ]) {
      test('4x4 forward ${tx.$1} matches the reference', () async {
        final input = [for (var i = 0; i < 16; i++) i * 7 - 50];
        await setUpDut(input);
        await runBlock(0, hType: tx.$2, vType: tx.$3);
        final expected = [
          for (final y in _xform2d(input, 4, tx.$2, tx.$3, 0)) y & 0xFFFF,
        ];
        expect(result(), equals(expected));
        await Simulator.endSimulation();
      });
    }

    test('8x8 forward DCT matches the integer reference', () async {
      final input = [for (var i = 0; i < 64; i++) (i % 9) * 6 - 24];
      await setUpDut(input);
      await runBlock(0, size: 1);
      final expected = [
        for (final y in _xform2d(input, 8, 0, 0, 0)) y & 0xFFFF,
      ];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('8x8 mixed ADST_DCT matches the integer reference', () async {
      final input = [for (var i = 0; i < 64; i++) (i % 7) * 5 - 15];
      await setUpDut(input);
      await runBlock(0, size: 1, hType: 1, vType: 0);
      final expected = [
        for (final y in _xform2d(input, 8, 1, 0, 0)) y & 0xFFFF,
      ];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('8x8 inverse FLIPADST_ADST matches the integer reference', () async {
      final input = [for (var i = 0; i < 64; i++) (i % 5) * 8 - 16];
      await setUpDut(input);
      await runBlock(1, size: 1, hType: 2, vType: 1);
      final expected = [
        for (final y in _xform2d(input, 8, 2, 1, 1)) y & 0xFFFF,
      ];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('4x4 inverse DCT with dequant matches the reference', () async {
      // Small quantized coefficients (as an entropy decoder would yield).
      final coeffs = [for (var i = 0; i < 16; i++) (i % 7) - 3];
      await setUpDut(coeffs);
      await runBlock(1, qp: 5, deq: true);
      final deq = _dequant(coeffs, 5);
      final expected = [for (final y in _xform2d(deq, 4, 0, 0, 1)) y & 0xFFFF];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });

    test('8x8 inverse ADST with dequant matches the reference', () async {
      final coeffs = [for (var i = 0; i < 64; i++) (i % 9) - 4];
      await setUpDut(coeffs);
      await runBlock(1, size: 1, hType: 1, vType: 1, qp: 8, deq: true);
      final deq = _dequant(coeffs, 8);
      final expected = [for (final y in _xform2d(deq, 8, 1, 1, 1)) y & 0xFFFF];
      expect(result(), equals(expected));
      await Simulator.endSimulation();
    });
  });

  group('HarborMediaEngine entropy-decode pipeline', () {
    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'decodes coefficients from a bitstream then inverse transforms',
      () async {
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.decodeOnly,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        // A 48-byte coded bitstream across the first three beats (MSB-first).
        final streamBytes = [for (var i = 0; i < 48; i++) (i * 29 + 13) & 0xFF];
        final bits = <int>[];
        for (final byte in streamBytes) {
          for (var i = 7; i >= 0; i--) {
            bits.add((byte >> i) & 1);
          }
        }

        final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 8);
        Logic rdata = Const(0, width: 128);
        for (var i = 15; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 8);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
              mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
              mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
              for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 16; i++)
                    If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable engine
        await bw(0x110, 0x0); // SESS_SRC_ADDR
        await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
        // SESS_CTRL: start | inverse | entropy-decode source, 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 4));
        for (var i = 0; i < 800; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: decode the 4x4 coefficient block then inverse DCT.
        final coeffs = _decodeBlock(bits, 16);
        final expected = [
          for (final y in _xform2d(coeffs, 4, 0, 0, 1)) y & 0xFFFF,
        ];

        final out = <int>[];
        for (final word in [mem[8], mem[9]]) {
          final v = word.value.toBigInt();
          for (var j = 0; j < 8; j++) {
            out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(out, equals(expected));
        await Simulator.endSimulation();
      },
    );

    test(
      'decodes a bitstream with the real od_ec coder then inverse transforms',
      () async {
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          useOdEc: true,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.decodeOnly,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        final streamBytes = [for (var i = 0; i < 48; i++) (i * 29 + 13) & 0xFF];

        final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 8);
        Logic rdata = Const(0, width: 128);
        for (var i = 15; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 8);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
              mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
              mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
              for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 16; i++)
                    If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR
        await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
        // start | inverse | entropy-decode source, 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 4));
        for (var i = 0; i < 800; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: od_ec coefficient decode (from the raw bytes) then inverse DCT.
        final coeffs = _decodeBlockOdEc(streamBytes, 16);
        final expected = [
          for (final y in _xform2d(coeffs, 4, 0, 0, 1)) y & 0xFFFF,
        ];

        final out = <int>[];
        for (final word in [mem[8], mem[9]]) {
          final v = word.value.toBigInt();
          for (var j = 0; j < 8; j++) {
            out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(out, equals(expected));
        await Simulator.endSimulation();
      },
    );

    test('decodes a 4x4 block in AV1 diagonal scan order', () async {
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      final streamBytes = [for (var i = 0; i < 48; i++) (i * 29 + 13) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }

      final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
            mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
            mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
            for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR
      await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
      // start | inverse | entropy-decode | AV1 scan order (bit 27), 4x4 DCT
      await bw(0x100, 0x1 | (1 << 1) | (1 << 4) | (1 << 27));
      for (var i = 0; i < 800; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      // Reference: decode in order, then scatter via the AV1 4x4 diagonal scan
      // (libaom default_scan_4x4) before the inverse transform.
      final coeffs = _decodeBlock(bits, 16);
      const scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
      final blockR = List.filled(16, 0);
      for (var k = 0; k < 16; k++) {
        blockR[scan4[k]] = coeffs[k];
      }
      final expected = [
        for (final y in _xform2d(blockR, 4, 0, 0, 1)) y & 0xFFFF,
      ];

      final out = <int>[];
      for (final word in [mem[8], mem[9]]) {
        final v = word.value.toBigInt();
        for (var j = 0; j < 8; j++) {
          out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
        }
      }
      expect(out, equals(expected));
      await Simulator.endSimulation();
    });

    test('streams an 8x8 block across multiple beats via DMA refill', () async {
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      // A 48-byte coded stream across the first three beats (the 8x8 decode
      // consumes more than the 64-bit window, forcing real DMA refills).
      final streamBytes = [for (var i = 0; i < 48; i++) (i * 53 + 11) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }
      BigInt packBeat(int off) {
        var v = BigInt.zero;
        for (var b = 0; b < 16; b++) {
          v |= BigInt.from(streamBytes[off + b] & 0xFF) << ((15 - b) * 8);
        }
        return v;
      }

      // Output (8x8 = 8 beats) goes to words 8..15, input words 0..2.
      final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            mem[0] < Const(packBeat(0), width: 128),
            mem[1] < Const(packBeat(16), width: 128),
            mem[2] < Const(packBeat(32), width: 128),
            for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR
      await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
      // start | inverse | size 8x8 | entropy-decode source, DCT
      await bw(0x100, 0x1 | (1 << 1) | (1 << 2) | (1 << 4));
      for (var i = 0; i < 1200; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      final coeffs = _decodeBlock(bits, 64);
      final expected = [
        for (final y in _xform2d(coeffs, 8, 0, 0, 1)) y & 0xFFFF,
      ];

      final out = <int>[];
      for (var w = 8; w < 16; w++) {
        final v = mem[w].value.toBigInt();
        for (var j = 0; j < 8; j++) {
          out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
        }
      }
      expect(out, equals(expected));
      await Simulator.endSimulation();
    });

    test('decode mode dequantizes coefficients before the transform', () async {
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      final streamBytes = [for (var i = 0; i < 48; i++) (i * 17 + 31) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }

      final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
            mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
            mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
            for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR
      await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
      await bw(0x150, 6); // SESS_QP
      // start | inverse | dequant enable | entropy-decode source, 4x4 DCT
      await bw(0x100, 0x1 | (1 << 1) | (1 << 3) | (1 << 4));
      for (var i = 0; i < 800; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      // Reference: decode coefficients, dequantize, then inverse DCT.
      final coeffs = _decodeBlock(bits, 16);
      final deq = _dequant(coeffs, 6);
      final expected = [for (final y in _xform2d(deq, 4, 0, 0, 1)) y & 0xFFFF];

      final out = <int>[];
      for (final word in [mem[8], mem[9]]) {
        final v = word.value.toBigInt();
        for (var j = 0; j < 8; j++) {
          out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
        }
      }
      expect(out, equals(expected));
      await Simulator.endSimulation();
    });
  });

  group('HarborMediaEngine intra reconstruction', () {
    tearDown(() async {
      await Simulator.reset();
    });

    int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    int _paeth(int a, int l, int al) {
      final base = a + l - al;
      if ((base - a).abs() <= (base - l).abs() &&
          (base - a).abs() <= (base - al).abs()) {
        return a;
      }
      return (base - l).abs() <= (base - al).abs() ? l : al;
    }

    for (final m in [0, 3]) {
      final names = {0: 'DC', 3: 'Paeth'};
      test('4x4 ${names[m]} reconstruct = prediction + residual', () async {
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.both,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        // Small coefficients (so the residual stays modest), neighbours.
        final coeffs = [for (var i = 0; i < 16; i++) (i % 3) * 4 - 4];
        final above = [for (var i = 0; i < 8; i++) (i * 20 + 30) & 0xFF];
        final left = [for (var i = 0; i < 8; i++) (i * 15 + 50) & 0xFF];
        const corner = 80;
        var nbrAv = BigInt.from(corner);
        for (var i = 0; i < 8; i++) {
          nbrAv |= BigInt.from(above[i]) << ((i + 1) * 8);
        }
        var nbrBv = BigInt.zero;
        for (var i = 0; i < 8; i++) {
          nbrBv |= BigInt.from(left[i]) << (i * 8);
        }

        final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 8);
        Logic rdata = Const(0, width: 128);
        for (var i = 15; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 8);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              mem[0] < Const(_pack(coeffs.sublist(0, 8)), width: 128),
              mem[1] < Const(_pack(coeffs.sublist(8, 16)), width: 128),
              mem[4] < Const(nbrAv, width: 128), // neighbours at word 4, 5
              mem[5] < Const(nbrBv, width: 128),
              for (final i in [2, 3, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
                mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 16; i++)
                    If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(10000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (coefficients)
        await bw(0x118, 0x40); // SESS_SRC_SIZE = neighbour address (word 4)
        await bw(0x120, 0x80); // SESS_DST_ADDR (memory word 8)
        // start | inverse | predict-enable | intra mode m, 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 5) | (m << 13));
        for (var i = 0; i < 400; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: inverse DCT -> residual -> predict + reconstruct.
        final res = _xform2d(coeffs, 4, 0, 0, 1);
        int s16(int v) {
          v &= 0xFFFF;
          return v >= 0x8000 ? v - 0x10000 : v;
        }

        var dc = 0;
        for (var i = 0; i < 4; i++) {
          dc += above[i] + left[i];
        }
        dc = (dc + 4) >> 3;
        final expected = <int>[];
        for (var r = 0; r < 4; r++) {
          for (var c = 0; c < 4; c++) {
            final residual = s16(res[r * 4 + c] & 0xFFFF);
            final pred = m == 0 ? dc : _paeth(above[c], left[r], corner);
            expected.add(_clampPx(pred + residual));
          }
        }

        final out = <int>[];
        for (final word in [mem[8], mem[9]]) {
          final v = word.value.toBigInt();
          for (var j = 0; j < 8; j++) {
            out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(out, equals(expected));
        await Simulator.endSimulation();
      });
    }
  });

  group('HarborMediaEngine inter reconstruction', () {
    tearDown(() async {
      await Simulator.reset();
    });

    int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    int _bilerp(int a, int b, int f) => ((16 - f) * a + f * b + 8) >> 4;
    int _s16(int v) {
      v &= 0xFFFF;
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    // The reference patch is 81 bytes packed low-byte-first across six beats.
    BigInt _packPatch(List<int> bytes, int off) {
      var v = BigInt.zero;
      for (var b = 0; b < 16; b++) {
        final byte = off + b < bytes.length ? bytes[off + b] : 0;
        v |= BigInt.from(byte & 0xFF) << (b * 8);
      }
      return v;
    }

    for (final mv in [(0, 0), (8, 8), (5, 11)]) {
      test(
        '4x4 motion comp frac (${mv.$1},${mv.$2}) + residual reconstructs',
        () async {
          final eng = HarborMediaEngine(
            baseAddress: 0x40000000,
            codecs: const [
              HarborCodecInstance(
                format: HarborCodecFormat.av1,
                capability: HarborCodecCapability.both,
              ),
            ],
          );
          final clk = SimpleClockGenerator(10).clk;
          final reset = Logic(name: 'reset');
          final stb = Logic(name: 'stb');
          final we = Logic(name: 'we');
          final adr = Logic(name: 'adr', width: 12);
          final mosi = Logic(name: 'mosi', width: 32);

          eng.input('clk').srcConnection! <= clk;
          eng.input('reset').srcConnection! <= reset;
          eng.input('bus_CYC').srcConnection! <= stb;
          eng.input('bus_STB').srcConnection! <= stb;
          eng.input('bus_WE').srcConnection! <= we;
          eng.input('bus_ADR').srcConnection! <= adr;
          eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
          eng.input('bus_SEL').srcConnection! <=
              Const(0xF, width: eng.input('bus_SEL').width);

          // Small coefficients (modest residual) and a 9x9 reference patch.
          final coeffs = [for (var i = 0; i < 16; i++) (i % 3) * 4 - 4];
          final patch = [
            for (var r = 0; r < 9; r++)
              [for (var c = 0; c < 9; c++) (r * 17 + c * 23 + 40) & 0xFF],
          ];
          final flatPatch = [
            for (var r = 0; r < 9; r++)
              for (var c = 0; c < 9; c++) patch[r][c],
          ];

          final mem = List.generate(
            16,
            (i) => Logic(name: 'mem_$i', width: 128),
          );
          final ridx = eng.output('dma_read_addr').getRange(4, 8);
          Logic rdata = Const(0, width: 128);
          for (var i = 15; i >= 0; i--) {
            rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
          }
          eng.input('dma_read_data').srcConnection! <= rdata;
          eng.input('dma_read_valid').srcConnection! <=
              eng.output('dma_read_req');
          final wreq = eng.output('dma_write_req');
          final widx = eng.output('dma_write_addr').getRange(4, 8);
          final wdata = eng.output('dma_write_data');
          eng.input('dma_write_ack').srcConnection! <= wreq;
          Sequential(clk, [
            If(
              reset,
              then: [
                mem[0] < Const(_pack(coeffs.sublist(0, 8)), width: 128),
                mem[1] < Const(_pack(coeffs.sublist(8, 16)), width: 128),
                // Reference patch beats at words 4..9.
                for (var i = 0; i < 6; i++)
                  mem[4 + i] < Const(_packPatch(flatPatch, i * 16), width: 128),
                for (final i in [2, 3, 10, 11, 12, 13, 14, 15])
                  mem[i] < Const(0, width: 128),
              ],
              orElse: [
                If(
                  wreq,
                  then: [
                    for (var i = 0; i < 16; i++)
                      If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                  ],
                ),
              ],
            ),
          ]);

          await eng.build();
          reset.inject(1);
          stb.inject(0);
          we.inject(0);
          adr.inject(0);
          mosi.inject(0);
          Simulator.setMaxSimTime(10000000);
          unawaited(Simulator.run());
          await clk.nextPosedge;
          await clk.nextPosedge;
          reset.inject(0);
          await clk.nextPosedge;

          Future<void> bw(int a, int d) async {
            adr.inject(a);
            mosi.inject(d);
            we.inject(1);
            stb.inject(1);
            await clk.nextPosedge;
            while (eng.output('bus_ACK').value.toInt() != 1) {
              await clk.nextPosedge;
            }
            stb.inject(0);
            we.inject(0);
            await clk.nextPosedge;
          }

          Future<int> br(int a) async {
            adr.inject(a);
            we.inject(0);
            stb.inject(1);
            await clk.nextPosedge;
            while (eng.output('bus_ACK').value.toInt() != 1) {
              await clk.nextPosedge;
            }
            final v = eng.output('bus_DAT_MISO').value.toInt();
            stb.inject(0);
            await clk.nextPosedge;
            return v;
          }

          await bw(0x00, 0x1); // enable
          await bw(0x110, 0x0); // SESS_SRC_ADDR (coefficients)
          await bw(
            0x118,
            0x40,
          ); // SESS_SRC_SIZE = reference patch addr (word 4)
          await bw(0x120, 10 * 16); // SESS_DST_ADDR (word 10)
          // start | inverse | inter-enable | frac_x<<16 | frac_y<<20, 4x4 DCT
          await bw(
            0x100,
            0x1 | (1 << 1) | (1 << 6) | (mv.$1 << 16) | (mv.$2 << 20),
          );
          for (var i = 0; i < 400; i++) {
            if ((await br(0x20)) & 0x1 == 0x1) break;
          }

          // Reference: inverse DCT residual, bilinear MC, then reconstruct.
          final res = _xform2d(coeffs, 4, 0, 0, 1);
          final hpass = [
            for (var r = 0; r < 9; r++)
              [
                for (var c = 0; c < 8; c++)
                  _bilerp(patch[r][c], patch[r][c + 1], mv.$1),
              ],
          ];
          final expected = <int>[];
          for (var r = 0; r < 4; r++) {
            for (var c = 0; c < 4; c++) {
              final interp = _bilerp(hpass[r][c], hpass[r + 1][c], mv.$2);
              expected.add(_clampPx(interp + _s16(res[r * 4 + c] & 0xFFFF)));
            }
          }

          final out = <int>[];
          for (final word in [mem[10], mem[11]]) {
            final v = word.value.toBigInt();
            for (var j = 0; j < 8; j++) {
              out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
            }
          }
          expect(out, equals(expected));
          await Simulator.endSimulation();
        },
      );
    }
  });

  group('HarborMediaEngine inter reconstruction 8-tap', () {
    tearDown(() async {
      await Simulator.reset();
    });

    int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    int _conv8(List<int> s, List<int> coef) {
      var acc = 0;
      for (var k = 0; k < 8; k++) {
        acc += s[k] * coef[k];
      }
      return (acc + 64) >> 7;
    }

    const reg = [
      [0, 0, 0, 128, 0, 0, 0, 0],
      [0, 2, -6, 126, 8, -2, 0, 0],
      [0, 2, -10, 122, 18, -4, 0, 0],
      [0, 2, -12, 116, 28, -8, 2, 0],
      [0, 2, -14, 110, 38, -10, 2, 0],
      [0, 2, -14, 102, 48, -12, 2, 0],
      [0, 2, -16, 94, 58, -12, 2, 0],
      [0, 2, -14, 84, 66, -12, 2, 0],
      [0, 2, -14, 76, 76, -14, 2, 0],
      [0, 2, -12, 66, 84, -14, 2, 0],
      [0, 2, -12, 58, 94, -16, 2, 0],
      [0, 2, -12, 48, 102, -14, 2, 0],
      [0, 2, -10, 38, 110, -14, 2, 0],
      [0, 2, -8, 28, 116, -12, 2, 0],
      [0, 0, -4, 18, 122, -10, 2, 0],
      [0, 0, -2, 8, 126, -6, 2, 0],
    ];
    const sharp = [
      [0, 0, 0, 128, 0, 0, 0, 0],
      [-2, 2, -6, 126, 8, -2, 2, 0],
      [-2, 6, -12, 124, 16, -6, 4, -2],
      [-2, 8, -18, 120, 26, -10, 6, -2],
      [-4, 10, -22, 116, 38, -14, 6, -2],
      [-4, 10, -22, 108, 48, -18, 8, -2],
      [-4, 10, -24, 100, 60, -20, 8, -2],
      [-4, 10, -24, 90, 70, -22, 10, -2],
      [-4, 12, -24, 80, 80, -24, 12, -4],
      [-2, 10, -22, 70, 90, -24, 10, -4],
      [-2, 8, -20, 60, 100, -24, 10, -4],
      [-2, 8, -18, 48, 108, -22, 10, -4],
      [-2, 6, -14, 38, 116, -22, 10, -4],
      [-2, 6, -10, 26, 120, -18, 8, -2],
      [-2, 4, -6, 16, 124, -12, 6, -2],
      [0, 2, -2, 8, 126, -6, 2, -2],
    ];
    final tables = [reg, sharp]; // filter_type 0 and 2 (mapped below)

    // The 15x15 patch is packed low-byte-first across 15 beats.
    BigInt _packPatch(List<int> bytes, int off) {
      var v = BigInt.zero;
      for (var b = 0; b < 16; b++) {
        final byte = off + b < bytes.length ? bytes[off + b] : 0;
        v |= BigInt.from(byte & 0xFF) << (b * 8);
      }
      return v;
    }

    for (final tc in [(0, 'regular', 5, 11), (2, 'sharp', 8, 8)]) {
      final filt = tc.$1;
      final fx = tc.$3;
      final fy = tc.$4;
      test('4x4 ${tc.$2} frac ($fx,$fy) + residual reconstructs', () async {
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          interpTaps: 8,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.both,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        final coeffs = [for (var i = 0; i < 16; i++) (i % 3) * 4 - 4];
        final patch = [
          for (var r = 0; r < 15; r++)
            [for (var c = 0; c < 15; c++) (r * 13 + c * 7 + 30) & 0xFF],
        ];
        final flatPatch = [
          for (var r = 0; r < 15; r++)
            for (var c = 0; c < 15; c++) patch[r][c],
        ];

        // 32-word memory model (5-bit word index) for the larger patch.
        final mem = List.generate(32, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 9);
        Logic rdata = Const(0, width: 128);
        for (var i = 31; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 5)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 9);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              mem[0] < Const(_pack(coeffs.sublist(0, 8)), width: 128),
              mem[1] < Const(_pack(coeffs.sublist(8, 16)), width: 128),
              // 15 reference-patch beats at words 4..18.
              for (var i = 0; i < 15; i++)
                mem[4 + i] < Const(_packPatch(flatPatch, i * 16), width: 128),
              for (final i in [2, 3, 19, 20, 21]) mem[i] < Const(0, width: 128),
              for (var i = 22; i < 32; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 32; i++)
                    If(widx.eq(Const(i, width: 5)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(10000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (coefficients)
        await bw(0x118, 0x40); // SESS_SRC_SIZE = reference patch addr (word 4)
        await bw(0x120, 19 * 16); // SESS_DST_ADDR (word 19)
        // start | inverse | inter-enable | frac_x<<16 | frac_y<<20 | filt<<24
        await bw(
          0x100,
          0x1 | (1 << 1) | (1 << 6) | (fx << 16) | (fy << 20) | (filt << 24),
        );
        for (var i = 0; i < 400; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: inverse DCT residual, 8-tap separable MC, then reconstruct.
        final res = _xform2d(coeffs, 4, 0, 0, 1);
        final table = tables[filt == 0 ? 0 : 1];
        final coefX = table[fx];
        final coefY = table[fy];
        final hpass = [
          for (var r = 0; r < 15; r++)
            [
              for (var c = 0; c < 8; c++)
                _conv8([for (var k = 0; k < 8; k++) patch[r][c + k]], coefX),
            ],
        ];
        int s16(int v) {
          v &= 0xFFFF;
          return v >= 0x8000 ? v - 0x10000 : v;
        }

        final expected = <int>[];
        for (var r = 0; r < 4; r++) {
          for (var c = 0; c < 4; c++) {
            final interp = _conv8([
              for (var k = 0; k < 8; k++) hpass[r + k][c],
            ], coefY);
            expected.add(_clampPx(interp + s16(res[r * 4 + c] & 0xFFFF)));
          }
        }

        final out = <int>[];
        for (final word in [mem[19], mem[20]]) {
          final v = word.value.toBigInt();
          for (var j = 0; j < 8; j++) {
            out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(out, equals(expected));
        await Simulator.endSimulation();
      });
    }
  });

  group('HarborMediaEngine tiled multi-block', () {
    tearDown(() async {
      await Simulator.reset();
    });

    int _clampPx(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);
    int _s16(int v) {
      v &= 0xFFFF;
      return v >= 0x8000 ? v - 0x10000 : v;
    }

    int _paeth(int a, int l, int al) {
      final base = a + l - al;
      final pa = (base - a).abs();
      final pl = (base - l).abs();
      final pal = (base - al).abs();
      if (pa <= pl && pa <= pal) return a;
      if (pl <= pal) return l;
      return al;
    }

    test(
      '2x2 grid of Paeth 4x4 blocks reconstructs via the line buffer',
      () async {
        const cols = 2, rows = 2, n = 4, fill = 128;
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.both,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        // Four 4x4 coefficient blocks (small, so residuals stay modest).
        final blocks = [
          for (var b = 0; b < cols * rows; b++)
            [for (var i = 0; i < 16; i++) ((i + b) % 3) * 3 - 3],
        ];

        // 16-word memory: 4 src blocks (words 0..7), 4 dst blocks (words 8..15).
        final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 8);
        Logic rdata = Const(0, width: 128);
        for (var i = 15; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 8);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              for (var b = 0; b < 4; b++) ...[
                mem[b * 2] < Const(_pack(blocks[b].sublist(0, 8)), width: 128),
                mem[b * 2 + 1] <
                    Const(_pack(blocks[b].sublist(8, 16)), width: 128),
              ],
              for (var i = 8; i < 16; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 16; i++)
                    If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (block 0 coeffs)
        await bw(0x120, 8 * 16); // SESS_DST_ADDR (memory word 8)
        await bw(0x130, cols); // SESS_WIDTH = block columns
        await bw(0x138, rows); // SESS_HEIGHT = block rows
        // start | inverse | predict-enable | tiled | Paeth mode (3<<13), 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 5) | (1 << 7) | (3 << 13));
        for (var i = 0; i < 1200; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: model the line buffer + Paeth reconstruct over the raster.
        final slots = [for (var c = 0; c < cols; c++) List.filled(n, fill)];
        final expected = <List<int>>[];
        var idx = 0;
        for (var brk = 0; brk < rows; brk++) {
          var left = List.filled(n, fill);
          var corner = fill;
          for (var bc = 0; bc < cols; bc++) {
            final above = slots[bc];
            final res = _xform2d(blocks[idx], n, 0, 0, 1);
            final recon = [for (var r = 0; r < n; r++) List.filled(n, 0)];
            for (var r = 0; r < n; r++) {
              for (var c = 0; c < n; c++) {
                final pred = _paeth(above[c], left[r], corner);
                recon[r][c] = _clampPx(pred + _s16(res[r * n + c] & 0xFFFF));
              }
            }
            final newCorner = slots[bc][n - 1];
            slots[bc] = [for (var c = 0; c < n; c++) recon[n - 1][c]];
            left = [for (var r = 0; r < n; r++) recon[r][n - 1]];
            corner = newCorner;
            expected.add([for (var r = 0; r < n; r++) ...recon[r]]);
            idx++;
          }
        }

        // Read back each block (row-major 4x4) from its destination words.
        for (var b = 0; b < cols * rows; b++) {
          final out = <int>[];
          for (final word in [mem[8 + b * 2], mem[9 + b * 2]]) {
            final v = word.value.toBigInt();
            for (var j = 0; j < 8; j++) {
              out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
            }
          }
          // 4x4 block is the first 16 of the 2 beats (stride-8 top-left packed).
          expect(out.sublist(0, 16), equals(expected[b]), reason: 'block $b');
        }
        await Simulator.endSimulation();
      },
    );

    test('2x2 grid decoded from one bitstream with persistent CDFs', () async {
      const cols = 2, rows = 2, n = 4, fill = 128;
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.decodeOnly,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      // A 48-byte coded stream (3 beats) feeding the whole 2x2 grid.
      final streamBytes = [for (var i = 0; i < 48; i++) (i * 47 + 9) & 0xFF];
      final bits = <int>[];
      for (final byte in streamBytes) {
        for (var i = 7; i >= 0; i--) {
          bits.add((byte >> i) & 1);
        }
      }

      // 16-word memory: stream at words 0..2, dst blocks at words 8..15.
      final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
            mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
            mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
            for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR (bitstream)
      await bw(0x120, 8 * 16); // SESS_DST_ADDR (memory word 8)
      await bw(0x130, cols); // SESS_WIDTH = block columns
      await bw(0x138, rows); // SESS_HEIGHT = block rows
      // start | inverse | entropy-decode | predict | tiled, DC mode, 4x4 DCT
      await bw(0x100, 0x1 | (1 << 1) | (1 << 4) | (1 << 5) | (1 << 7));
      for (var i = 0; i < 4000; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      // Reference: decode all blocks from one stream (persistent CDFs), then
      // inverse-transform + DC reconstruct through the modelled line buffer.
      final range = _Range(bits);
      final ctxs = _freshCtxs();
      final coeffBlocks = [
        for (var b = 0; b < cols * rows; b++) _decodeBlockWith(range, ctxs, 16),
      ];
      int s16(int v) {
        v &= 0xFFFF;
        return v >= 0x8000 ? v - 0x10000 : v;
      }

      final slots = [for (var c = 0; c < cols; c++) List.filled(n, fill)];
      final expected = <List<int>>[];
      var idx = 0;
      for (var brk = 0; brk < rows; brk++) {
        var left = List.filled(n, fill);
        for (var bc = 0; bc < cols; bc++) {
          final above = slots[bc];
          final res = _xform2d(coeffBlocks[idx], n, 0, 0, 1);
          var dcv = 0;
          for (var i = 0; i < n; i++) {
            dcv += above[i] + left[i];
          }
          dcv = (dcv + n) >> 3;
          final recon = [for (var r = 0; r < n; r++) List.filled(n, 0)];
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              recon[r][c] = _clampPx(dcv + s16(res[r * n + c] & 0xFFFF));
            }
          }
          slots[bc] = [for (var c = 0; c < n; c++) recon[n - 1][c]];
          left = [for (var r = 0; r < n; r++) recon[r][n - 1]];
          expected.add([for (var r = 0; r < n; r++) ...recon[r]]);
          idx++;
        }
      }

      for (var b = 0; b < cols * rows; b++) {
        final out = <int>[];
        for (final word in [mem[8 + b * 2], mem[9 + b * 2]]) {
          final v = word.value.toBigInt();
          for (var j = 0; j < 8; j++) {
            out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(out.sublist(0, 16), equals(expected[b]), reason: 'block $b');
      }
      await Simulator.endSimulation();
    });

    test(
      '2x2 grid decoded from one bitstream with the real od_ec coder',
      () async {
        const cols = 2, rows = 2, n = 4, fill = 128;
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          useOdEc: true,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.decodeOnly,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        final streamBytes = [for (var i = 0; i < 48; i++) (i * 47 + 9) & 0xFF];

        final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 8);
        Logic rdata = Const(0, width: 128);
        for (var i = 15; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 8);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              mem[0] < Const(_packBeat(streamBytes, 0), width: 128),
              mem[1] < Const(_packBeat(streamBytes, 16), width: 128),
              mem[2] < Const(_packBeat(streamBytes, 32), width: 128),
              for (var i = 3; i < 16; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 16; i++)
                    If(widx.eq(Const(i, width: 4)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (bitstream)
        await bw(0x120, 8 * 16); // SESS_DST_ADDR (memory word 8)
        await bw(0x130, cols); // SESS_WIDTH = block columns
        await bw(0x138, rows); // SESS_HEIGHT = block rows
        // start | inverse | entropy-decode | predict | tiled, DC mode, 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 4) | (1 << 5) | (1 << 7));
        for (var i = 0; i < 4000; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        // Reference: one persistent od_ec window + contexts across the grid.
        final od = _OdEc(streamBytes);
        final ctxs = _freshOdEcCtxs();
        final coeffBlocks = [
          for (var b = 0; b < cols * rows; b++)
            _decodeBlockOdEcWith(od, ctxs, 16),
        ];
        int s16(int v) {
          v &= 0xFFFF;
          return v >= 0x8000 ? v - 0x10000 : v;
        }

        final slots = [for (var c = 0; c < cols; c++) List.filled(n, fill)];
        final expected = <List<int>>[];
        var idx = 0;
        for (var brk = 0; brk < rows; brk++) {
          var left = List.filled(n, fill);
          for (var bc = 0; bc < cols; bc++) {
            final above = slots[bc];
            final res = _xform2d(coeffBlocks[idx], n, 0, 0, 1);
            var dcv = 0;
            for (var i = 0; i < n; i++) {
              dcv += above[i] + left[i];
            }
            dcv = (dcv + n) >> 3;
            final recon = [for (var r = 0; r < n; r++) List.filled(n, 0)];
            for (var r = 0; r < n; r++) {
              for (var c = 0; c < n; c++) {
                recon[r][c] = _clampPx(dcv + s16(res[r * n + c] & 0xFFFF));
              }
            }
            slots[bc] = [for (var c = 0; c < n; c++) recon[n - 1][c]];
            left = [for (var r = 0; r < n; r++) recon[r][n - 1]];
            expected.add([for (var r = 0; r < n; r++) ...recon[r]]);
            idx++;
          }
        }

        for (var b = 0; b < cols * rows; b++) {
          final out = <int>[];
          for (final word in [mem[8 + b * 2], mem[9 + b * 2]]) {
            final v = word.value.toBigInt();
            for (var j = 0; j < 8; j++) {
              out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
            }
          }
          expect(out.sublist(0, 16), equals(expected[b]), reason: 'block $b');
        }
        await Simulator.endSimulation();
      },
    );

    test('2x2 grid of 4x4 blocks lands in a 2D frame buffer', () async {
      const cols = 2, rows = 2, n = 4, fill = 128;
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      // Four 4x4 coefficient blocks -> an 8x8 frame (2x2 grid).
      final blocks = [
        for (var b = 0; b < cols * rows; b++)
          [for (var i = 0; i < 16; i++) ((i + b * 2) % 3) * 3 - 3],
      ];

      // Frame buffer at words 8..15 (one beat per frame row), byte-enable
      // honoured so the two 4x4 columns can share a beat.
      final mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 8);
      Logic rdata = Const(0, width: 128);
      for (var i = 15; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 4)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 8);
      final wdata = eng.output('dma_write_data');
      final wbe = eng.output('dma_write_be');
      final mask = [
        for (var byte = 15; byte >= 0; byte--) wbe[byte].replicate(8),
      ].swizzle();
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            for (var b = 0; b < 4; b++) ...[
              mem[b * 2] < Const(_pack(blocks[b].sublist(0, 8)), width: 128),
              mem[b * 2 + 1] <
                  Const(_pack(blocks[b].sublist(8, 16)), width: 128),
            ],
            for (var i = 8; i < 16; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 16; i++)
                  If(
                    widx.eq(Const(i, width: 4)),
                    then: [mem[i] < ((mem[i] & ~mask) | (wdata & mask))],
                  ),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR (coeffs)
      await bw(0x120, 8 * 16); // SESS_DST_ADDR (frame base, word 8)
      await bw(0x130, cols); // SESS_WIDTH = block columns
      await bw(0x138, rows); // SESS_HEIGHT = block rows
      // start | inverse | predict | tiled | 2D, DC mode, 4x4 DCT
      await bw(0x100, 0x1 | (1 << 1) | (1 << 5) | (1 << 7) | (1 << 12));
      for (var i = 0; i < 1200; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      // Reference: line buffer DC reconstruct, placed at raster (x,y).
      int s16(int v) {
        v &= 0xFFFF;
        return v >= 0x8000 ? v - 0x10000 : v;
      }

      final frame = [for (var y = 0; y < 8; y++) List.filled(8, 0)];
      final slots = [for (var c = 0; c < cols; c++) List.filled(n, fill)];
      var idx = 0;
      for (var brk = 0; brk < rows; brk++) {
        var left = List.filled(n, fill);
        for (var bc = 0; bc < cols; bc++) {
          final above = slots[bc];
          final res = _xform2d(blocks[idx], n, 0, 0, 1);
          var dcv = 0;
          for (var i = 0; i < n; i++) {
            dcv += above[i] + left[i];
          }
          dcv = (dcv + n) >> 3;
          final recon = [for (var r = 0; r < n; r++) List.filled(n, 0)];
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              recon[r][c] = _clampPx(dcv + s16(res[r * n + c] & 0xFFFF));
              frame[brk * n + r][bc * n + c] = recon[r][c];
            }
          }
          slots[bc] = [for (var c = 0; c < n; c++) recon[n - 1][c]];
          left = [for (var r = 0; r < n; r++) recon[r][n - 1]];
          idx++;
        }
      }

      // Each frame row is one beat of 8 samples at word 8 + y.
      for (var y = 0; y < 8; y++) {
        final v = mem[8 + y].value.toBigInt();
        final row = [
          for (var x = 0; x < 8; x++)
            ((v >> (x * 16)) & BigInt.from(0xFFFF)).toInt(),
        ];
        expect(row, equals(frame[y]), reason: 'frame row $y');
      }
      await Simulator.endSimulation();
    });

    test(
      '1x3 grid of 4x4 inter blocks (per-block patches) reconstructs',
      () async {
        const cols = 3, rows = 1, n = 4;
        const fx = 5, fy = 11;
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.both,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        final blocks = [
          for (var b = 0; b < cols; b++)
            [for (var i = 0; i < 16; i++) ((i + b) % 3) * 3 - 3],
        ];
        // A distinct 9x9 reference patch per block.
        final patches = [
          for (var b = 0; b < cols; b++)
            [
              for (var r = 0; r < 9; r++)
                [
                  for (var c = 0; c < 9; c++)
                    (r * 13 + c * 7 + b * 40 + 30) & 0xFF,
                ],
            ],
        ];
        final flatPatches = [
          for (var b = 0; b < cols; b++)
            [
              for (var r = 0; r < 9; r++)
                for (var c = 0; c < 9; c++) patches[b][r][c],
            ],
        ];
        BigInt packPatchBeat(List<int> flat, int beat) {
          var v = BigInt.zero;
          for (var by = 0; by < 16; by++) {
            final k = beat * 16 + by;
            if (k < flat.length) v |= BigInt.from(flat[k] & 0xFF) << (by * 8);
          }
          return v;
        }

        // 32-word memory: 3 coeff blocks (words 0..5), 3 patch blobs of 6 beats
        // (words 6..23), dst blocks (words 24..29).
        final mem = List.generate(32, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 9);
        Logic rdata = Const(0, width: 128);
        for (var i = 31; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 5)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 9);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        Sequential(clk, [
          If(
            reset,
            then: [
              for (var b = 0; b < cols; b++) ...[
                mem[b * 2] < Const(_pack(blocks[b].sublist(0, 8)), width: 128),
                mem[b * 2 + 1] <
                    Const(_pack(blocks[b].sublist(8, 16)), width: 128),
              ],
              for (var b = 0; b < cols; b++)
                for (var beat = 0; beat < 6; beat++)
                  mem[6 + b * 6 + beat] <
                      Const(packPatchBeat(flatPatches[b], beat), width: 128),
              for (var i = 24; i < 32; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 32; i++)
                    If(widx.eq(Const(i, width: 5)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (coeffs)
        await bw(0x118, 6 * 16); // SESS_SRC_SIZE = patch base (word 6)
        await bw(0x120, 24 * 16); // SESS_DST_ADDR (word 24)
        await bw(0x130, cols); // SESS_WIDTH = block columns
        await bw(0x138, rows); // SESS_HEIGHT = block rows
        // start | inverse | inter | tiled | frac_x<<16 | frac_y<<20, 4x4 DCT
        await bw(
          0x100,
          0x1 | (1 << 1) | (1 << 6) | (1 << 7) | (fx << 16) | (fy << 20),
        );
        for (var i = 0; i < 1200; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        int s16(int v) {
          v &= 0xFFFF;
          return v >= 0x8000 ? v - 0x10000 : v;
        }

        int bilerp(int a, int b, int f) => ((16 - f) * a + f * b + 8) >> 4;
        final expected = <List<int>>[];
        for (var b = 0; b < cols; b++) {
          final res = _xform2d(blocks[b], n, 0, 0, 1);
          final hpass = [
            for (var r = 0; r < 9; r++)
              [
                for (var c = 0; c < 8; c++)
                  bilerp(patches[b][r][c], patches[b][r][c + 1], fx),
              ],
          ];
          final blk = <int>[];
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              final interp = bilerp(hpass[r][c], hpass[r + 1][c], fy);
              blk.add(_clampPx(interp + s16(res[r * n + c] & 0xFFFF)));
            }
          }
          expected.add(blk);
        }

        for (var b = 0; b < cols; b++) {
          final out = <int>[];
          for (final word in [mem[24 + b * 2], mem[25 + b * 2]]) {
            final v = word.value.toBigInt();
            for (var j = 0; j < 8; j++) {
              out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
            }
          }
          expect(out.sublist(0, 16), equals(expected[b]), reason: 'block $b');
        }
        await Simulator.endSimulation();
      },
    );

    test(
      '2x1 grid of 4x4 inter blocks gathered (signed MV, ref border)',
      () async {
        const cols = 2, rows = 1, n = 4;
        // The reference buffer carries a 1-row top border (refBase points at
        // buffer row 1), so a negative mvy reads into it.
        const refStride = 16, refH = 11;
        // Per-block motion: (mvx, mvy, frac_x, frac_y), block 0 has mvy = -1.
        const mvs = [(1, -1, 5, 11), (2, 1, 3, 7)];
        final eng = HarborMediaEngine(
          baseAddress: 0x40000000,
          codecs: const [
            HarborCodecInstance(
              format: HarborCodecFormat.av1,
              capability: HarborCodecCapability.both,
            ),
          ],
        );
        final clk = SimpleClockGenerator(10).clk;
        final reset = Logic(name: 'reset');
        final stb = Logic(name: 'stb');
        final we = Logic(name: 'we');
        final adr = Logic(name: 'adr', width: 12);
        final mosi = Logic(name: 'mosi', width: 32);

        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);

        final blocks = [
          for (var b = 0; b < cols; b++)
            [for (var i = 0; i < 16; i++) ((i + b) % 3) * 3 - 3],
        ];
        // Reference frame: refH rows x refStride samples (low byte = pixel).
        final refFrame = [
          for (var y = 0; y < refH; y++)
            [for (var x = 0; x < refStride; x++) (y * 23 + x * 11 + 17) & 0xFF],
        ];

        // 32-word memory: coeffs 0..3, motion field 4..5, reference buffer 6..27
        // (refH=11 rows x 2 beats), dst 28..31. refBase = buffer row 1 (word 8).
        final mem = List.generate(32, (i) => Logic(name: 'mem_$i', width: 128));
        final ridx = eng.output('dma_read_addr').getRange(4, 9);
        Logic rdata = Const(0, width: 128);
        for (var i = 31; i >= 0; i--) {
          rdata = mux(ridx.eq(Const(i, width: 5)), mem[i], rdata);
        }
        eng.input('dma_read_data').srcConnection! <= rdata;
        eng.input('dma_read_valid').srcConnection! <=
            eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        final widx = eng.output('dma_write_addr').getRange(4, 9);
        final wdata = eng.output('dma_write_data');
        eng.input('dma_write_ack').srcConnection! <= wreq;
        BigInt mvBeat(int b) {
          final m = mvs[b];
          return BigInt.from(
            (m.$1 & 0xFF) | ((m.$2 & 0xFF) << 8) | (m.$3 << 16) | (m.$4 << 20),
          );
        }

        Sequential(clk, [
          If(
            reset,
            then: [
              for (var b = 0; b < cols; b++) ...[
                mem[b * 2] < Const(_pack(blocks[b].sublist(0, 8)), width: 128),
                mem[b * 2 + 1] <
                    Const(_pack(blocks[b].sublist(8, 16)), width: 128),
              ],
              mem[4] < Const(mvBeat(0), width: 128),
              mem[5] < Const(mvBeat(1), width: 128),
              for (var y = 0; y < refH; y++) ...[
                mem[6 + y * 2] <
                    Const(_pack(refFrame[y].sublist(0, 8)), width: 128),
                mem[6 + y * 2 + 1] <
                    Const(_pack(refFrame[y].sublist(8, 16)), width: 128),
              ],
              for (var i = 28; i < 32; i++) mem[i] < Const(0, width: 128),
            ],
            orElse: [
              If(
                wreq,
                then: [
                  for (var i = 0; i < 32; i++)
                    If(widx.eq(Const(i, width: 5)), then: [mem[i] < wdata]),
                ],
              ),
            ],
          ),
        ]);

        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        Simulator.setMaxSimTime(20000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

        Future<void> bw(int a, int d) async {
          adr.inject(a);
          mosi.inject(d);
          we.inject(1);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          stb.inject(0);
          we.inject(0);
          await clk.nextPosedge;
        }

        Future<int> br(int a) async {
          adr.inject(a);
          we.inject(0);
          stb.inject(1);
          await clk.nextPosedge;
          while (eng.output('bus_ACK').value.toInt() != 1) {
            await clk.nextPosedge;
          }
          final v = eng.output('bus_DAT_MISO').value.toInt();
          stb.inject(0);
          await clk.nextPosedge;
          return v;
        }

        await bw(0x00, 0x1); // enable
        await bw(0x110, 0x0); // SESS_SRC_ADDR (coeffs)
        await bw(
          0x118,
          8 * 16,
        ); // SESS_SRC_SIZE = ref base = buffer row 1 (word 8)
        await bw(0x120, 28 * 16); // SESS_DST_ADDR (word 28)
        await bw(0x128, 4 * 16); // SESS_DST_SIZE = motion field base (word 4)
        await bw(0x140, refStride); // SESS_REF_STRIDE (samples/row)
        await bw(0x130, cols); // SESS_WIDTH = block columns
        await bw(0x138, rows); // SESS_HEIGHT = block rows
        // start | inverse | inter | tiled | real-gather, 4x4 DCT
        await bw(0x100, 0x1 | (1 << 1) | (1 << 6) | (1 << 7) | (1 << 26));
        for (var i = 0; i < 1500; i++) {
          if ((await br(0x20)) & 0x1 == 0x1) break;
        }

        int s16(int v) {
          v &= 0xFFFF;
          return v >= 0x8000 ? v - 0x10000 : v;
        }

        int bilerp(int a, int b, int f) => ((16 - f) * a + f * b + 8) >> 4;
        final expected = <List<int>>[];
        for (var b = 0; b < cols; b++) {
          final m = mvs[b];
          final pbx = b * n + m.$1;
          final pby = m.$2;
          // refBase is buffer row 1, so the reference row is 1 + pby + pr.
          final patch = [
            for (var pr = 0; pr < 9; pr++)
              [
                for (var c = 0; c < 9; c++)
                  refFrame[1 + pby + pr][pbx + c] & 0xFF,
              ],
          ];
          final res = _xform2d(blocks[b], n, 0, 0, 1);
          final hpass = [
            for (var pr = 0; pr < 9; pr++)
              [
                for (var c = 0; c < 8; c++)
                  bilerp(patch[pr][c], patch[pr][c + 1], m.$3),
              ],
          ];
          final blk = <int>[];
          for (var r = 0; r < n; r++) {
            for (var c = 0; c < n; c++) {
              final interp = bilerp(hpass[r][c], hpass[r + 1][c], m.$4);
              blk.add(_clampPx(interp + s16(res[r * n + c] & 0xFFFF)));
            }
          }
          expected.add(blk);
        }

        for (var b = 0; b < cols; b++) {
          final out = <int>[];
          for (final word in [mem[28 + b * 2], mem[29 + b * 2]]) {
            final v = word.value.toBigInt();
            for (var j = 0; j < 8; j++) {
              out.add(((v >> (j * 16)) & BigInt.from(0xFFFF)).toInt());
            }
          }
          expect(out.sublist(0, 16), equals(expected[b]), reason: 'block $b');
        }
        await Simulator.endSimulation();
      },
    );

    test('1x2 grid of 8x8 blocks lands in a 2D frame buffer', () async {
      const cols = 2, rows = 1, n = 8, fill = 128;
      final eng = HarborMediaEngine(
        baseAddress: 0x40000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
      );
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final stb = Logic(name: 'stb');
      final we = Logic(name: 'we');
      final adr = Logic(name: 'adr', width: 12);
      final mosi = Logic(name: 'mosi', width: 32);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('bus_CYC').srcConnection! <= stb;
      eng.input('bus_STB').srcConnection! <= stb;
      eng.input('bus_WE').srcConnection! <= we;
      eng.input('bus_ADR').srcConnection! <= adr;
      eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
      eng.input('bus_SEL').srcConnection! <=
          Const(0xF, width: eng.input('bus_SEL').width);

      // Two 8x8 coefficient blocks -> an 8x16 frame (1x2 grid).
      final blocks = [
        for (var b = 0; b < cols * rows; b++)
          [for (var i = 0; i < 64; i++) ((i + b * 5) % 7) - 3],
      ];

      // 32-word memory: 2 src blocks (words 0..15), frame at words 16..31.
      final mem = List.generate(32, (i) => Logic(name: 'mem_$i', width: 128));
      final ridx = eng.output('dma_read_addr').getRange(4, 9);
      Logic rdata = Const(0, width: 128);
      for (var i = 31; i >= 0; i--) {
        rdata = mux(ridx.eq(Const(i, width: 5)), mem[i], rdata);
      }
      eng.input('dma_read_data').srcConnection! <= rdata;
      eng.input('dma_read_valid').srcConnection! <= eng.output('dma_read_req');
      final wreq = eng.output('dma_write_req');
      final widx = eng.output('dma_write_addr').getRange(4, 9);
      final wdata = eng.output('dma_write_data');
      final wbe = eng.output('dma_write_be');
      final mask = [
        for (var byte = 15; byte >= 0; byte--) wbe[byte].replicate(8),
      ].swizzle();
      eng.input('dma_write_ack').srcConnection! <= wreq;
      Sequential(clk, [
        If(
          reset,
          then: [
            for (var b = 0; b < 2; b++)
              for (var beat = 0; beat < 8; beat++)
                mem[b * 8 + beat] <
                    Const(
                      _pack(blocks[b].sublist(beat * 8, beat * 8 + 8)),
                      width: 128,
                    ),
            for (var i = 16; i < 32; i++) mem[i] < Const(0, width: 128),
          ],
          orElse: [
            If(
              wreq,
              then: [
                for (var i = 0; i < 32; i++)
                  If(
                    widx.eq(Const(i, width: 5)),
                    then: [mem[i] < ((mem[i] & ~mask) | (wdata & mask))],
                  ),
              ],
            ),
          ],
        ),
      ]);

      await eng.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      Simulator.setMaxSimTime(20000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      Future<void> bw(int a, int d) async {
        adr.inject(a);
        mosi.inject(d);
        we.inject(1);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        stb.inject(0);
        we.inject(0);
        await clk.nextPosedge;
      }

      Future<int> br(int a) async {
        adr.inject(a);
        we.inject(0);
        stb.inject(1);
        await clk.nextPosedge;
        while (eng.output('bus_ACK').value.toInt() != 1) {
          await clk.nextPosedge;
        }
        final v = eng.output('bus_DAT_MISO').value.toInt();
        stb.inject(0);
        await clk.nextPosedge;
        return v;
      }

      await bw(0x00, 0x1); // enable
      await bw(0x110, 0x0); // SESS_SRC_ADDR (coeffs)
      await bw(0x120, 16 * 16); // SESS_DST_ADDR (frame base, word 16)
      await bw(0x130, cols); // SESS_WIDTH = block columns
      await bw(0x138, rows); // SESS_HEIGHT = block rows
      // start | inverse | size 8x8 | predict | tiled | 2D, DC mode
      await bw(
        0x100,
        0x1 | (1 << 1) | (1 << 2) | (1 << 5) | (1 << 7) | (1 << 12),
      );
      for (var i = 0; i < 2000; i++) {
        if ((await br(0x20)) & 0x1 == 0x1) break;
      }

      int s16(int v) {
        v &= 0xFFFF;
        return v >= 0x8000 ? v - 0x10000 : v;
      }

      // Reference: line buffer DC reconstruct over the row, placed at (x,y).
      final frame = [for (var y = 0; y < 8; y++) List.filled(16, 0)];
      final slots = [for (var c = 0; c < cols; c++) List.filled(n, fill)];
      var left = List.filled(n, fill);
      for (var bc = 0; bc < cols; bc++) {
        final above = slots[bc];
        final res = _xform2d(blocks[bc], n, 0, 0, 1);
        var dcv = 0;
        for (var i = 0; i < n; i++) {
          dcv += above[i] + left[i];
        }
        dcv = (dcv + n) >> 4;
        final recon = [for (var r = 0; r < n; r++) List.filled(n, 0)];
        for (var r = 0; r < n; r++) {
          for (var c = 0; c < n; c++) {
            recon[r][c] = _clampPx(dcv + s16(res[r * n + c] & 0xFFFF));
            frame[r][bc * n + c] = recon[r][c];
          }
        }
        slots[bc] = [for (var c = 0; c < n; c++) recon[n - 1][c]];
        left = [for (var r = 0; r < n; r++) recon[r][n - 1]];
      }

      // Frame row y spans words 16 + y*2 (samples 0..7) and +1 (samples 8..15).
      for (var y = 0; y < 8; y++) {
        final row = <int>[];
        for (final word in [mem[16 + y * 2], mem[17 + y * 2]]) {
          final v = word.value.toBigInt();
          for (var x = 0; x < 8; x++) {
            row.add(((v >> (x * 16)) & BigInt.from(0xFFFF)).toInt());
          }
        }
        expect(row, equals(frame[y]), reason: 'frame row $y');
      }
      await Simulator.endSimulation();
    });
  });
}

void _registerBusTests(HarborFabricKind kind) {
  group('HarborMediaEngine register bus (${kind.name})', () {
    late HarborMediaEngine eng;
    late Logic clk, reset;
    late RegBus bus;

    Future<void> setUpDut() async {
      eng = HarborMediaEngine(
        baseAddress: 0x20000000,
        codecs: const [
          HarborCodecInstance(
            format: HarborCodecFormat.av1,
            capability: HarborCodecCapability.both,
          ),
        ],
        fabricKind: kind,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      bus = RegBus.attach(eng, clk);

      eng.input('clk').srcConnection! <= clk;
      eng.input('reset').srcConnection! <= reset;
      eng.input('dma_read_data').srcConnection! <= Const(0, width: 128);
      eng.input('dma_read_valid').srcConnection! <= Const(0);
      eng.input('dma_write_ack').srcConnection! <= Const(0);

      await eng.build();
      bus.idle();
      reset.inject(1);
      Simulator.setMaxSimTime(200000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    tearDown(() async {
      await Simulator.reset();
    });

    test(
      'global and per-session registers read back what was written',
      () async {
        await setUpDut();

        await bus.write(0x28, 0x3); // INT_ENABLE
        expect(await bus.read(0x28), equals(0x3));

        await bus.write(0x118, 0x11223344); // session 0 SESS_SRC_SIZE
        expect(await bus.read(0x118), equals(0x11223344));

        await bus.write(0x130, 0x1234); // session 0 SESS_WIDTH
        expect(await bus.read(0x130), equals(0x1234));

        await Simulator.endSimulation();
      },
    );

    test('a write with no byte selected changes nothing', () async {
      await setUpDut();

      await bus.write(0x118, 0x11223344);
      await bus.write(0x28, 0x3);

      await bus.write(0x118, 0xffffffff, sel: 0x0);
      await bus.write(0x28, 0x0, sel: 0x0);

      expect(await bus.read(0x118), equals(0x11223344));
      expect(await bus.read(0x28), equals(0x3));

      await Simulator.endSimulation();
    });
  });
}
