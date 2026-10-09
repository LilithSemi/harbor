import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../soc/device_tree.dart';

/// Configuration for [HarborTrng].
class HarborTrngConfig {
  /// Base address in the SoC memory map.
  final int baseAddress;

  /// Deterministic seed for the DRBG.
  ///
  /// When non-zero the generator produces a repeatable, deterministic
  /// stream (a 32-bit xorshift seeded with [seed]) so that simulation is
  /// reproducible. When zero the generator continuously reseeds itself
  /// from the entropy pool fed by the raw `noise` input.
  final int seed;

  const HarborTrngConfig({required this.baseAddress, this.seed = 0});
}

/// Reusable hardware True Random Number Generator block.
///
/// A raw 1-bit `noise` input (driven by a PDK ring-oscillator or other
/// physical entropy source on ASIC, or an LFSR/metastable source on FPGA)
/// feeds an entropy pool. A deterministic DRBG (a 32-bit xorshift) is
/// reseeded from that pool and produces the random words read back through
/// the bus. SP 800-90B style continuous health tests
/// (repetition-count + adaptive-proportion) watch the raw noise source and
/// raise a failure flag when it appears stuck or unhealthy.
///
/// Register map (Wishbone slave `bus`, 32-bit):
/// - `0x00 RAND`   (read-only) next DRBG output word, reading advances the
///   generator.
/// - `0x04 STATUS` (read-only) bit0 = ready, bit1 = health-test failed.
///
/// When [HarborTrngConfig.seed] is non-zero the DRBG runs as a pure
/// deterministic xorshift stream so simulation is repeatable. The entropy
/// pool still tracks the noise source for the health tests but does not
/// perturb the output.
class HarborTrng extends BridgeModule with HarborDeviceTreeNodeProvider {
  /// Configuration.
  final HarborTrngConfig config;

  /// Wishbone slave bus.
  late final BusSlavePort bus;

  /// Raw 1-bit entropy input (ring oscillator / metastable source).
  Logic get noise => input('noise');

  // Repetition-count health test: a stuck source repeating the same bit for
  // this many consecutive samples is declared unhealthy (SP 800-90B style
  // cutoff for a 1-bit source). The cutoff is the true identical-sample run
  // length: a run of exactly [_repetitionCutoff] identical samples trips it.
  static const int _repetitionCutoff = 64;

  // Adaptive-proportion health test: over a window of [_apWindow] samples, if
  // more than [_apCutoff] match the window reference the source is unhealthy.
  static const int _apWindow = 512;
  static const int _apCutoff = 500;

  HarborTrng(
    this.config, {
    BusProtocol protocol = BusProtocol.wishbone,
    int? busDataWidth,
    String? name,
  }) : super('HarborTrng', name: name ?? 'trng') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Raw entropy input pin (PDK ring-oscillator attaches here).
    createPort('noise', PortDirection.input);

    // On a >=64-bit fabric the SEP's 64-bit master places a 32-bit access's data
    // on the lane selected by the byte offset, so registers must be 8-BYTE
    // STRIDED (each on the low 32 lanes, distinct by ADR) and BYTE-addressed,
    // matching harbor's CLINT and the Albion subsystems. On the 32-bit bus we
    // keep the original WORD-addressed 4-byte map so existing users are
    // unaffected. The register logic always uses the low 32 data lanes.
    final wide = (busDataWidth ?? 32) >= 64;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: protocol,
      clk: input('clk'),
      reset: input('reset'),
      addressWidth: wide ? 32 : 12,
      dataWidth: busDataWidth ?? 32,
    );

    final clk = input('clk');
    final reset = input('reset');
    final noiseBit = input('noise');

    // 32-bit register view on the LOW data lanes (the bus may be 32 or 64 wide).
    final datOut32 = Logic(name: 'trng_dat_out', width: 32);
    bus.dataOut <= datOut32.zeroExtend(bus.dataOut.width);

    // Register address field + offsets: byte-addressed 8-byte stride on a
    // 64-bit fabric, else byte-addressed 4-byte stride, matching the ADR
    // convention every other Harbor peripheral uses. The narrow path used to
    // compare a word index (addr >> 2) against the byte address on ADR, so
    // only RAND at word index 0 (which is also byte address 0) ever matched
    // and STATUS was unreachable. Only the bits of the 0x1000 window are
    // decoded, so absolute and relative addresses both work.
    final addrField = bus.windowAddr(0x1000);
    final randOff = Const(0x00, width: addrField.width);
    final statusOff = Const(wide ? 0x08 : 0x04, width: addrField.width);

    // DRBG state (xorshift32).
    final state = Logic(name: 'drbg_state', width: 32);

    // Entropy pool: shift register fed one raw noise bit per clock.
    final pool = Logic(name: 'entropy_pool', width: 32);

    // Readiness: high one cycle after reset deasserts.
    final ready = Logic(name: 'ready');

    // Health test state.
    final repCount = Logic(
      name: 'rep_count',
      width: _repetitionCutoff.bitLength,
    );
    final lastSample = Logic(name: 'last_sample');
    final apCounter = Logic(name: 'ap_counter', width: _apWindow.bitLength);
    final apMatches = Logic(name: 'ap_matches', width: _apWindow.bitLength);
    final apRef = Logic(name: 'ap_ref');
    final healthFailed = Logic(name: 'health_failed');

    // Seed used at reset: deterministic when configured, else a fixed
    // non-zero default that the entropy pool then perturbs.
    final seedValue = config.seed != 0 ? config.seed : 0x1;
    final deterministic = config.seed != 0;

    // Next xorshift32 value of [state].
    Logic xorshift(Logic s) {
      final a = s ^ (s << 13);
      final b = a ^ (a >>> 17);
      final c = b ^ (b << 5);
      return c;
    }

    Sequential(clk, [
      If(
        reset,
        then: [
          state < Const(seedValue, width: 32),
          pool < Const(0, width: 32),
          ready < Const(0),
          repCount < Const(0, width: repCount.width),
          lastSample < Const(0),
          apCounter < Const(0, width: apCounter.width),
          apMatches < Const(0, width: apMatches.width),
          apRef < Const(0),
          healthFailed < Const(0),
          bus.ack < Const(0),
          datOut32 < Const(0, width: 32),
        ],
        orElse: [
          ready < Const(1),

          // Shift the raw noise bit into the entropy pool every cycle.
          pool < [pool.getRange(0, 31), noiseBit].swizzle(),

          // Repetition-count: count consecutive identical samples. [repCount]
          // holds the length of the current identical-sample run (a fresh run
          // starts at 1). When this sample matches the previous one the run
          // grows, the test trips once the run reaches [_repetitionCutoff]
          // samples, so the constant is the true run length that fails.
          If(
            noiseBit.eq(lastSample),
            then: [
              If(
                repCount.lt(Const(_repetitionCutoff, width: repCount.width)),
                then: [repCount < repCount + 1],
              ),
              If(
                (repCount + 1).gte(
                  Const(_repetitionCutoff, width: repCount.width),
                ),
                then: [healthFailed < Const(1)],
              ),
            ],
            orElse: [repCount < Const(1, width: repCount.width)],
          ),
          lastSample < noiseBit,

          // Adaptive-proportion: over a window, count matches to a reference.
          If(
            apCounter.eq(Const(0, width: apCounter.width)),
            then: [
              // Start a new window: latch reference, reset counters.
              apRef < noiseBit,
              apMatches < Const(0, width: apMatches.width),
              apCounter < Const(1, width: apCounter.width),
            ],
            orElse: [
              If(noiseBit.eq(apRef), then: [apMatches < apMatches + 1]),
              If(
                apCounter.gte(Const(_apWindow - 1, width: apCounter.width)),
                then: [
                  // Window complete: evaluate and restart.
                  If(
                    apMatches.gte(Const(_apCutoff, width: apMatches.width)),
                    then: [healthFailed < Const(1)],
                  ),
                  apCounter < Const(0, width: apCounter.width),
                ],
                orElse: [apCounter < apCounter + 1],
              ),
            ],
          ),

          // Default bus outputs.
          bus.ack < Const(0),
          datOut32 < Const(0, width: 32),

          If(
            bus.stb & ~bus.ack,
            then: [
              bus.ack < Const(1),
              Case(addrField, [
                // RAND: present the current DRBG word and advance.
                CaseItem(randOff, [
                  datOut32 < state,
                  If(
                    ~bus.we,
                    then: [
                      // Advance. In non-deterministic mode fold in entropy.
                      // xorshift(0)==0, so a noise-mode state can self-lock at
                      // zero if both state and pool reach 0. OR in 1 in noise
                      // mode to keep the state non-zero and avoid that lock.
                      // Deterministic mode is left untouched so its golden
                      // stream is unchanged.
                      state <
                          (deterministic
                              ? xorshift(state)
                              : (xorshift(state) ^ pool) | Const(1, width: 32)),
                    ],
                  ),
                ]),
                // STATUS: bit0 ready, bit1 health failed.
                CaseItem(statusOff, [
                  datOut32 <
                      [Const(0, width: 30), healthFailed, ready].swizzle(),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);
  }

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: ['lilithsemi,harbor-trng'],
    reg: BusAddressRange(config.baseAddress, 0x1000),
    properties: {
      'lilithsemi,seeded': config.seed != 0 ? 1 : 0,
      '#address-cells': 1,
      '#size-cells': 1,
    },
  );
}
