import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Sdram pad ports of [HarborSdram], in the same order as the board catalog.
const sdramPadPorts = [
  'sdram_clk',
  'sdram_cke',
  'sdram_cs_n',
  'sdram_ras_n',
  'sdram_cas_n',
  'sdram_we_n',
  'sdram_ba',
  'sdram_addr',
  'sdram_dqm',
  'sdram_dq',
];

/// 32-bit words in the whole AS4C16M16SB-6 address space (32 MiB), for
/// [SdramBistMaster.words] when a run should sweep the full device instead
/// of the default 256 KiB.
const fullSweepBistWords = 32 * 1024 * 1024 ~/ 4;

/// Wishbone master that tests sdram, then loops. `pass` goes high after
/// the first clean pass. `fail` is sticky.
///
/// Default mode writes an lfsr pattern over [words] 32-bit words and reads
/// it back. With [addressLineWalk], it instead writes a distinct tag to
/// word 0 and to each power-of-two word offset below [words], then reads
/// them all back: a shorted or stuck address line aliases two of these
/// onto one cell, so a later tag overwrites an earlier one and a readback
/// disagrees with what that address was given.
class SdramBistMaster extends Module {
  /// 32-bit words per pass.
  final int words;

  /// Walk the address lines instead of sweeping every word.
  final bool addressLineWalk;

  Logic get cyc => output('cyc');
  Logic get we => output('we');
  Logic get adr => output('adr');
  Logic get datW => output('dat_w');
  Logic get pass => output('pass');
  Logic get fail => output('fail');
  Logic get loops => output('loops');

  SdramBistMaster({
    required Logic clk,
    required Logic reset,
    required Logic ready,
    required Logic ack,
    required Logic datR,
    required int adrWidth,
    this.words = 65536,
    this.addressLineWalk = false,
  }) : super(name: 'bist') {
    if (words < 2 || words & (words - 1) != 0) {
      throw ArgumentError('words must be a power of two, got $words');
    }
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    ready = addInput('ready', ready);
    ack = addInput('ack', ack);
    datR = addInput('dat_r', datR, width: 32);

    final idxBits = words.bitLength - 1;
    final cyc = addOutput('cyc');
    final we = addOutput('we');
    final adr = addOutput('adr', width: adrWidth);
    final datW = addOutput('dat_w', width: 32);
    final pass = addOutput('pass');
    final fail = addOutput('fail');
    final loops = addOutput('loops', width: 8);

    // Two flops bring the mem_clk ready flag onto this clock.
    final ready0 = flop(clk, ready, reset: reset);
    final readySync = flop(clk, ready0, reset: reset);

    final reading = Logic(name: 'reading');
    final started = Logic(name: 'started');

    if (!addressLineWalk) {
      final idx = Logic(name: 'idx', width: idxBits);
      final lfsr = Logic(name: 'lfsr', width: 32);
      final last = idx.eq(Const(words - 1, width: idxBits));
      Logic seedOf(Logic n) => Const(0xace11234, width: 32) ^ n.zeroExtend(32);
      // Galois lfsr, x^32 + x^22 + x^2 + x + 1.
      final next = mux(
        lfsr[0],
        (lfsr >>> 1) ^ Const(0x80200003, width: 32),
        lfsr >>> 1,
      );

      adr <= [idx, Const(0, width: 2)].swizzle().zeroExtend(adrWidth);
      datW <= lfsr;
      we <= ~reading;

      Sequential(clk, reset: reset, [
        If(
          ~started,
          then: [
            If(readySync, then: [started < 1, cyc < 1, lfsr < seedOf(loops)]),
          ],
          orElse: [
            If(
              cyc & ack,
              then: [
                If(reading & datR.neq(lfsr), then: [fail < 1]),
                idx < idx + 1,
                reading < reading ^ last,
                If(
                  ~last,
                  then: [lfsr < next],
                  orElse: [
                    If(
                      reading,
                      then: [
                        loops < loops + 1,
                        lfsr < seedOf(loops + 1),
                        If(~fail, then: [pass < 1]),
                      ],
                      orElse: [lfsr < seedOf(loops)],
                    ),
                  ],
                ),
                // Drop cyc for one cycle between accesses.
                cyc < 0,
              ],
              orElse: [cyc < 1],
            ),
          ],
        ),
      ]);
      return;
    }

    // Address-line walk: word 0, then 1 << 0, 1 << 1, ... 1 << (idxBits-1).
    final walkAddrs = [0, for (var k = 0; k < idxBits; k++) 1 << k];
    final n = walkAddrs.length;
    final stepWidth = (n - 1).bitLength < 1 ? 1 : (n - 1).bitLength;
    final step = Logic(name: 'step', width: stepWidth);
    final idxW = cases(
      step,
      {
        for (var i = 0; i < n; i++)
          Const(i, width: stepWidth): Const(walkAddrs[i], width: idxBits),
      },
      defaultValue: Const(0, width: idxBits),
      conditionalType: ConditionalType.unique,
    );
    final pattern = idxW.zeroExtend(32) ^ Const(0xc0ffee00, width: 32);
    final last = step.eq(Const(n - 1, width: stepWidth));

    adr <= [idxW, Const(0, width: 2)].swizzle().zeroExtend(adrWidth);
    datW <= pattern;
    we <= ~reading;

    Sequential(clk, reset: reset, [
      If(
        ~started,
        then: [If(readySync, then: [started < 1, cyc < 1])],
        orElse: [
          If(
            cyc & ack,
            then: [
              If(reading & datR.neq(pattern), then: [fail < 1]),
              step < mux(last, Const(0, width: stepWidth), step + 1),
              reading < reading ^ last,
              If(
                last & reading,
                then: [loops < loops + 1, If(~fail, then: [pass < 1])],
              ),
              cyc < 0,
            ],
            orElse: [cyc < 1],
          ),
        ],
      ),
    ]);
  }
}

/// Ulx3s top for the sdram place and route check and the board test.
///
/// One ehxplll makes the 125 MHz sdram clock (clkop) and the 62.5 MHz sys
/// clock (clkos). A [SdramBistMaster] on sys drives [HarborSdram] through
/// the cdc. Leds: 0 init done, 1 pass, 2 fail, 7..3 loop count.
class SdramUlx3sTop extends BridgeModule {
  late final HarborSdram sdram;
  late final HarborClockDomain memDomain;
  late final HarborClockDomain sysDomain;

  SdramUlx3sTop({
    required HarborFpgaTarget target,
    int bistWords = 65536,
    bool bistAddressLineWalk = false,
  }) : super('SdramUlx3sTop', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('rst_n', PortDirection.input);
    addOutput('led', width: 8);

    final gen = HarborClockGenerator(
      parent: this,
      inputClk: input('clk'),
      inputReset: ~input('rst_n'),
      target: target,
    );
    final pair = gen.createDomainWithSecondary(
      HarborClockConfig.fixed(
        name: 'sdram',
        frequency: 125000000,
        sourceFrequency: 25000000,
      ),
      secondaryFrequency: 62500000,
      secondaryName: 'sys',
    );
    memDomain = pair.primary;
    sysDomain = pair.secondary;

    sdram = HarborSdram(
      config: const HarborSdramConfig.as4c16m16sb6(),
      baseAddress: 0,
      clockHz: 125000000,
      target: target,
    );
    addSubModule(sdram);
    sdram.input('clk').srcConnection! <= sysDomain.clk;
    sdram.input('reset').srcConnection! <= sysDomain.reset;
    sdram.input('mem_clk').srcConnection! <= memDomain.clk;
    sdram.input('mem_reset').srcConnection! <= memDomain.reset;

    final bist = SdramBistMaster(
      clk: sysDomain.clk,
      reset: sysDomain.reset,
      ready: sdram.output('init_done'),
      ack: sdram.output('bus_ACK'),
      datR: sdram.output('bus_DAT_MISO'),
      adrWidth: sdram.bus.addr.width,
      words: bistWords,
      addressLineWalk: bistAddressLineWalk,
    );
    sdram.input('bus_CYC').srcConnection! <= bist.cyc;
    sdram.input('bus_STB').srcConnection! <= bist.cyc;
    sdram.input('bus_WE').srcConnection! <= bist.we;
    sdram.input('bus_ADR').srcConnection! <= bist.adr;
    sdram.input('bus_DAT_MOSI').srcConnection! <= bist.datW;
    sdram.input('bus_SEL').srcConnection! <= Const(0xf, width: 4);

    output('led') <=
        [
          bist.loops.getRange(0, 5),
          bist.fail,
          bist.pass,
          sdram.output('init_done'),
        ].swizzle();

    for (final p in sdramPadPorts) {
      pullUpPort(sdram.port(p), newPortName: p);
    }
  }
}
