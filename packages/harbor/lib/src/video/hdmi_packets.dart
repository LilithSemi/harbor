import 'package:rohd/rohd.dart';

/// The audio sample rates of an HDMI audio build, in `audio_fs_sel` order.
/// The select value 3 is [fs48000].
enum HdmiAudioRate {
  fs32000(32000, 4096, 0x3),
  fs44100(44100, 6272, 0x0),
  fs48000(48000, 6144, 0x2);

  /// The sample rate in Hz.
  final int hz;

  /// The recommended N of HDMI 1.4 section 7.2.1.
  final int recommendedN;

  /// IEC 60958-3 channel status bits 27..24, bit 24 in bit 0.
  final int iecCode;

  const HdmiAudioRate(this.hz, this.recommendedN, this.iecCode);
}

/// N and CTS of the audio clock regeneration (HDMI 1.4 section 7.2).
///
/// A pixel clock within 100 ppm of a row of the HDMI 1.4 tables 7-1 to
/// 7-3 (25.2, 27, 74.25 and 148.5 MHz, and the same clocks scaled by 1.001)
/// gets the N and CTS of that row. Another clock gets N = 128 * fs / 1000
/// and CTS = round(pixelClock * N / (128 * fs)). The fs generator and the
/// ACR packet use this same pair, so the strobe rate is
/// `pixelClock * N / (128 * CTS)`, the fs that the sink regenerates.
abstract final class HdmiAcr {
  static const _rows = <(double, List<(int, int)>)>[
    (25200000 / 1.001, [(4576, 28125), (7007, 31250), (6864, 28125)]),
    (25200000, [(4096, 25200), (6272, 28000), (6144, 25200)]),
    (27000000, [(4096, 27000), (6272, 30000), (6144, 27000)]),
    (27027000, [(4096, 27027), (6272, 30030), (6144, 27027)]),
    (74250000 / 1.001, [(11648, 210938), (17836, 234375), (11648, 140625)]),
    (74250000, [(4096, 74250), (6272, 82500), (6144, 74250)]),
    (148500000 / 1.001, [(5824, 210938), (8918, 234375), (5824, 140625)]),
    (148500000, [(4096, 148500), (6272, 165000), (6144, 148500)]),
  ];

  /// The largest fs error that [values] accepts, in ppm.
  static const maxErrorPpm = 1000;

  /// N and CTS for [rate] at [pixelClock] Hz. It throws when CTS does not
  /// fit in 20 bits or the fs error is over [maxErrorPpm].
  static (int, int) values(int pixelClock, HdmiAudioRate rate) {
    final unit = 128 * rate.hz;
    int n;
    int cts;
    final row = _rows
        .where((r) => (pixelClock - r.$1).abs() <= r.$1 * 100e-6)
        .firstOrNull;
    if (row != null) {
      (n, cts) = row.$2[rate.index];
    } else {
      n = (unit / 1000).round();
      cts = (pixelClock * n + unit ~/ 2) ~/ unit;
    }
    if (cts < 1 || cts >= 1 << 20 || cts * 128 <= n) {
      throw ArgumentError(
        'CTS $cts for ${rate.hz} Hz audio at a pixel clock of $pixelClock Hz '
        'is out of range',
      );
    }
    final ppm = (pixelClock * n / (unit * cts) - 1).abs() * 1e6;
    if (ppm > maxErrorPpm) {
      throw ArgumentError(
        'the sample rate error of ${rate.hz} Hz audio at a pixel clock of '
        '$pixelClock Hz is ${ppm.round()} ppm, the limit is $maxErrorPpm ppm',
      );
    }
    return (n, cts);
  }
}

/// The audio sample strobe and the ACR period on the pixel clock.
///
/// [fsSel] is in the pixel domain. A new value applies when it is the same
/// for two clocks. Then the generator starts again from 0.
///
/// An accumulator adds N in each clock and subtracts 128 * CTS when it
/// gets to that value. Each subtraction gives one [strobe]. So the
/// strobe rate is `pixelClock * N / (128 * CTS)`, as in [HdmiAcr]. [acr] is
/// high once in each CTS clocks. All values are integers, so there is no
/// drift.
class HdmiAudioRateGen extends Module {
  /// One clock in each sample period.
  Logic get strobe => output('strobe');

  /// One clock in each CTS clocks.
  Logic get acr => output('acr');

  /// The applied select, 0 to 2.
  Logic get rate => output('rate');

  /// N of the applied rate, 20 bits.
  Logic get n => output('n');

  /// CTS of the applied rate, 20 bits.
  Logic get cts => output('cts');

  final int pixelClock;

  HdmiAudioRateGen({
    required Logic clk,
    required Logic reset,
    required Logic fsSel,
    required this.pixelClock,
    super.name = 'audio_rate',
  }) : super(definitionName: 'HdmiAudioRateGen_p$pixelClock') {
    final pairs = [
      for (final r in HdmiAudioRate.values) HdmiAcr.values(pixelClock, r),
    ];
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    fsSel = addInput('fs_sel', fsSel, width: 2);
    addOutput('strobe');
    addOutput('acr');
    addOutput('rate', width: 2);
    addOutput('n', width: 20);
    addOutput('cts', width: 20);

    final maxCts = pairs.map((p) => p.$2).reduce((a, b) => a > b ? a : b);
    final aw = (128 * maxCts).bitLength;
    final cw = maxCts.bitLength;
    final applied = Logic(name: 'rate_applied', width: 2);
    final last = Logic(name: 'fs_sel_last', width: 2);
    final acc = Logic(name: 'acc', width: aw);
    final count = Logic(name: 'cts_count', width: cw);
    final strobeReg = Logic(name: 'strobe_reg');
    final acrReg = Logic(name: 'acr_reg');

    Logic pick(int Function((int, int)) f, int width) => mux(
      applied.eq(0),
      Const(f(pairs[0]), width: width),
      mux(
        applied.eq(1),
        Const(f(pairs[1]), width: width),
        Const(f(pairs[2]), width: width),
      ),
    );

    final want = mux(fsSel.eq(3), Const(2, width: 2), fsSel);
    final change = (fsSel.eq(last) & want.neq(applied)).named('rate_change');
    // 128 * CTS - N: the accumulator wraps at this value or above.
    final top = pick((p) => 128 * p.$2 - p.$1, aw).named('acc_top');
    final wrap = acc.gte(top).named('acc_wrap');
    final ctsEnd = count.eq(pick((p) => p.$2 - 1, cw)).named('cts_end');

    Sequential(
      clk,
      reset: reset,
      resetValues: {applied: 2},
      [
        last < fsSel,
        If(
          change,
          then: [applied < want, acc < 0, count < 0, strobeReg < 0, acrReg < 0],
          orElse: [
            acc < mux(wrap, acc - top, acc + pick((p) => p.$1, aw)),
            count < mux(ctsEnd, Const(0, width: cw), count + 1),
            strobeReg < wrap,
            acrReg < ctsEnd,
          ],
        ),
      ],
    );
    strobe <= strobeReg;
    acr <= acrReg;
    rate <= applied;
    n <= pick((p) => p.$1, 20);
    cts <= pick((p) => p.$2, 20);
  }
}

/// Feeds an [HdmiFramer] with ACR, audio sample, AVI InfoFrame and Audio
/// InfoFrame packets, in that priority order. All ports are in the pixel
/// domain.
///
/// One packet register holds the offered packet. When it is empty, it
/// loads the source of the highest priority that has a packet. An audio
/// packet with fewer than 4 samples goes after the InfoFrames, so a high
/// sample rate in a short blank does not stop them. The ACR
/// packet is due once in each CTS clocks (see [HdmiAudioRateGen]). The two
/// InfoFrames are due at each [frame] pulse. A source that is still due
/// at its next due time, or a sample with no space, makes one [missed]
/// pulse. The due packet then goes out later.
///
/// At each sample strobe the scheduler pops one stereo sample: it reads
/// [sampleLeft] and [sampleRight] and makes [samplePop] high when
/// [sampleValid] is high. Else it uses a zero sample and makes one
/// [underrun] pulse. Up to 4 samples go in one audio sample packet
/// (HDMI 1.4 section 5.3.4, layout 0). Each subframe has valid bit 0, user
/// bit 0, the IEC 60958-3 consumer channel status bit (L-PCM, the fs of
/// the applied rate, 24-bit words) and even parity. B marks the first
/// frame of each 192 frame block.
///
/// The AVI InfoFrame (CEA-861 version 2) says RGB, no colorimetry data,
/// [vic], the quantization range [aviQ] (Q1:Q0) and the picture aspect
/// ratio [aviM] (M1:M0). The active format ratio R is "same as picture"
/// when [aviM] is not 0, else 0. The Audio InfoFrame says 2 channels and
/// refers to the stream header for the coding type, the sample size and the
/// fs. While [active] is low, the scheduler does not pop samples and does
/// not count underruns.
class HdmiPacketScheduler extends Module {
  Logic get packetValid => output('packet_valid');
  Logic get packetHeader => output('packet_header');
  Logic packetSubpacket(int k) => output('packet_subpacket_$k');
  Logic get samplePop => output('sample_pop');
  Logic get underrun => output('underrun');
  Logic get missed => output('missed');

  late final HdmiAudioRateGen rateGen;

  /// AVI InfoFrame header HB0..HB2, HB0 in bits 7..0.
  static const aviHeader = 0x0D0282;

  /// Audio InfoFrame header.
  static const audioInfoHeader = 0x0A0184;

  /// Audio InfoFrame PB1: CT 0 (refer to stream header), 2 channels.
  static const audioInfoPb1 = 0x01;

  /// IEC 60958-3 channel status bits that are 1 for every rate: bit 2 (no
  /// copyright), bit 32 (24-bit maximum word length) and bits 33 and 35
  /// (24 bits).
  static const channelStatusWordLength = [2, 32, 33, 35];

  HdmiPacketScheduler({
    required Logic clk,
    required Logic reset,
    required Logic frame,
    required Logic vic,
    required Logic aviQ,
    required Logic aviM,
    required Logic active,
    required Logic fsSel,
    required Logic sampleValid,
    required Logic sampleLeft,
    required Logic sampleRight,
    required Logic packetReady,
    required int pixelClock,
    super.name = 'hdmi_packets',
  }) : super(definitionName: 'HdmiPacketScheduler_p$pixelClock') {
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    frame = addInput('frame', frame);
    vic = addInput('vic', vic, width: 7);
    aviQ = addInput('avi_q', aviQ, width: 2);
    aviM = addInput('avi_m', aviM, width: 2);
    active = addInput('active', active);
    fsSel = addInput('fs_sel', fsSel, width: 2);
    sampleValid = addInput('sample_valid', sampleValid);
    sampleLeft = addInput('sample_left', sampleLeft, width: 24);
    sampleRight = addInput('sample_right', sampleRight, width: 24);
    packetReady = addInput('packet_ready', packetReady);
    addOutput('packet_valid');
    addOutput('packet_header', width: 24);
    for (var k = 0; k < 4; k++) {
      addOutput('packet_subpacket_$k', width: 56);
    }
    addOutput('sample_pop');
    addOutput('underrun');
    addOutput('missed');

    final gen = rateGen = HdmiAudioRateGen(
      clk: clk,
      reset: reset,
      fsSel: fsSel,
      pixelClock: pixelClock,
    );
    final strobe = gen.strobe;

    final slotValid = Logic(name: 'slot_valid');
    final slotHeader = Logic(name: 'slot_header', width: 24);
    final slotSub = [
      for (var k = 0; k < 4; k++) Logic(name: 'slot_subpacket_$k', width: 56),
    ];
    final acrDue = Logic(name: 'acr_due');
    final aviDue = Logic(name: 'avi_due');
    final aifDue = Logic(name: 'aif_due');
    final count = Logic(name: 'sample_count', width: 3);
    final col = [
      for (var k = 0; k < 4; k++) Logic(name: 'sample_sub_$k', width: 56),
    ];
    final colB = Logic(name: 'sample_block', width: 4);
    final frameNo = Logic(name: 'iec_frame', width: 8);

    final free = ~slotValid;
    // A partial audio packet waits for a due InfoFrame.
    final hasAudio = (count.neq(0) & (count.eq(4) | ~(aviDue | aifDue))).named(
      'audio_due',
    );
    final loadAcr = (free & acrDue).named('load_acr');
    final loadAudio = (free & ~acrDue & hasAudio).named('load_audio');
    final loadAvi = (free & ~acrDue & ~hasAudio & aviDue).named('load_avi');
    final loadAif = (free & ~acrDue & ~hasAudio & ~aviDue & aifDue).named(
      'load_aif',
    );
    final take = (slotValid & packetReady).named('slot_take');

    // A sample goes in at index 0 when the packet loads in the same clock.
    final room = (loadAudio | count.lt(4)).named('sample_room');
    final write = (strobe & room).named('sample_write');
    final index = mux(loadAudio, Const(0, width: 3), count);
    final have = (sampleValid & active).named('sample_have');
    final left = mux(have, sampleLeft, Const(0, width: 24));
    final right = mux(have, sampleRight, Const(0, width: 24));

    Logic frameIs(int v) => frameNo.eq(Const(v, width: 8));
    var cs = channelStatusWordLength.map(frameIs).reduce((a, b) => a | b);
    for (var b = 0; b < 4; b++) {
      final rates = [
        for (final r in HdmiAudioRate.values)
          if (r.iecCode >> b & 1 == 1) r.index,
      ];
      if (rates.isEmpty) continue;
      final match = rates
          .map((i) => gen.rate.eq(Const(i, width: 2)))
          .reduce((a, b) => a | b);
      cs = cs | (frameIs(24 + b) & match);
    }
    cs = cs.named('channel_status_bit');
    // Byte 6: PR CR UR VR PL CL UL VL.
    final status = [
      right.xor() ^ cs,
      cs,
      Const(0, width: 2),
      left.xor() ^ cs,
      cs,
      Const(0, width: 2),
    ].swizzle();
    final sub = [status, right, left].swizzle().named('sample_subpacket');

    // ACR: SB1..SB3 CTS, SB4..SB6 N, high byte first (section 5.3.3).
    Logic bytes20(Logic v) => [
      v.getRange(0, 8),
      v.getRange(8, 16),
      v.getRange(16, 20).zeroExtend(8),
    ].swizzle();
    final acrSub = [
      bytes20(gen.n),
      bytes20(gen.cts),
      Const(0, width: 8),
    ].swizzle();

    // AVI: PB2 is M1:M0 and R3:R0, PB3 has Q1:Q0, PB4 is the VIC. The
    // other bytes are 0.
    final pb2 = [
      Const(0, width: 2),
      aviM,
      mux(aviM.neq(0), Const(8, width: 4), Const(0, width: 4)),
    ].swizzle().named('avi_pb2');
    final pb3 = [
      Const(0, width: 4),
      aviQ,
      Const(0, width: 2),
    ].swizzle().named('avi_pb3');
    final pb4 = vic.zeroExtend(8);
    final aviSum = Const(
      (aviHeader & 0xff) + (aviHeader >> 8 & 0xff) + (aviHeader >> 16),
      width: 8,
    );
    final aviCheck = (Const(0, width: 8) - (aviSum + pb2 + pb3 + pb4)).named(
      'avi_checksum',
    );
    final aviSub = [
      Const(0, width: 16),
      pb4,
      pb3,
      pb2,
      Const(0, width: 8),
      aviCheck,
    ].swizzle();
    const aifSum =
        (audioInfoHeader & 0xff) +
        (audioInfoHeader >> 8 & 0xff) +
        (audioInfoHeader >> 16) +
        audioInfoPb1;
    const aifSub0 = audioInfoPb1 << 8 | (-aifSum & 0xff);

    final present = mux(
      count.eq(1),
      Const(1, width: 4),
      mux(
        count.eq(2),
        Const(3, width: 4),
        mux(count.eq(3), Const(7, width: 4), Const(15, width: 4)),
      ),
    );
    final audioHeader = [
      colB,
      Const(0, width: 4),
      Const(0, width: 4),
      present,
      Const(0x02, width: 8),
    ].swizzle();
    final zero56 = Const(0, width: 56);

    final missedNow =
        ((strobe & ~room) |
                (gen.acr & acrDue & ~loadAcr) |
                (frame & aviDue & ~loadAvi) |
                (frame & aifDue & ~loadAif))
            .named('missed_now');

    Sequential(clk, reset: reset, [
      If(
        gen.acr,
        then: [acrDue < 1],
        orElse: [
          If(loadAcr, then: [acrDue < 0]),
        ],
      ),
      If(
        frame,
        then: [aviDue < 1],
        orElse: [
          If(loadAvi, then: [aviDue < 0]),
        ],
      ),
      If(
        frame,
        then: [aifDue < 1],
        orElse: [
          If(loadAif, then: [aifDue < 0]),
        ],
      ),
      If(take, then: [slotValid < 0]),
      If.block([
        Iff(loadAcr, [
          slotValid < 1,
          slotHeader < Const(0x000001, width: 24),
          for (final s in slotSub) s < acrSub,
        ]),
        Iff(loadAudio, [
          slotValid < 1,
          slotHeader < audioHeader,
          for (var k = 0; k < 4; k++)
            slotSub[k] < (k == 0 ? col[0] : mux(count.gt(k), col[k], zero56)),
        ]),
        Iff(loadAvi, [
          slotValid < 1,
          slotHeader < Const(aviHeader, width: 24),
          slotSub[0] < aviSub,
          for (var k = 1; k < 4; k++) slotSub[k] < zero56,
        ]),
        Iff(loadAif, [
          slotValid < 1,
          slotHeader < Const(audioInfoHeader, width: 24),
          slotSub[0] < Const(aifSub0, width: 56),
          for (var k = 1; k < 4; k++) slotSub[k] < zero56,
        ]),
      ]),
      If(
        write,
        then: [
          for (var k = 0; k < 4; k++) If(index.eq(k), then: [col[k] < sub]),
          count < index + 1,
          colB <
              mux(loadAudio, Const(0, width: 4), colB) |
                  mux(
                    frameIs(0),
                    Const(1, width: 4) << index,
                    Const(0, width: 4),
                  ),
          frameNo < mux(frameIs(191), Const(0, width: 8), frameNo + 1),
        ],
        orElse: [
          If(loadAudio, then: [count < 0, colB < 0]),
        ],
      ),
    ]);

    packetValid <= slotValid;
    packetHeader <= slotHeader;
    for (var k = 0; k < 4; k++) {
      packetSubpacket(k) <= slotSub[k];
    }
    samplePop <= strobe & have;
    underrun <= strobe & ~sampleValid & active;
    missed <= missedNow;
  }
}
