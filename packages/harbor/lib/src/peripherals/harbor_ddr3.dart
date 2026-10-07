import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../bus/bus.dart';
import '../bus/bus_slave_port.dart';
import '../clock/wishbone_cdc_fifo.dart';
import '../soc/acpi.dart';
import '../soc/device_tree.dart';
import '../soc/svd.dart';
import '../soc/target.dart';
import 'ddr3_config.dart' show HarborDdrConfig, HarborDdrType;
import 'ddr3_burst_adapter.dart';
import 'ddr3_controller.dart';
import 'ddr3_gearbox.dart';
import 'ddr3_params.dart';
import 'ddr3_phy.dart';
import 'ddr3_phy_base.dart';
import 'ddr3_phy_ecp5.dart';

/// Clean SoC wrapper for the production [Ddr3Controller] + [Ddr3Phy] (the
/// UberDDR3-derived, silicon-proven stack: read/write calibration + multi-row
/// bank management verified on the Arty S7).
///
/// It presents one fixed external contract so genip wires it the same way on
/// every target: a Wishbone-B4 slave `'bus'`, the DDR3 clock
/// inputs (`clk`, `reset`, `ddr_clk`, `ddr_reset`, `ddr_ck_fast`,
/// `ddr_ck90_fast`, `ddr_ck_dqs_fast`, `ddr_idelay_ref`), and the `sdram_*`
/// pads. Internally:
///
///   bus (sys clk, 32b B4) -> HarborWishboneCdcFifoBridge('ddr_cdc', 32b)
///     -> Ddr3BurstAdapter (32<->128, B4<->pipelined) -> Ddr3Controller (128b)
///     -> Ddr3Phy -> sdram_* pads          (all on ddr_clk = CK/4)
///
/// No writeVerify / readLevel / trainableRead workarounds: the controller
/// self-calibrates and keeps the bus stalled (o_wb_stall high) until
/// calibration completes, so a CPU access naturally waits for a ready array.
///
/// On an ECP5 target the PHY is [Ddr3PhyEcp5]. Clock contract there:
/// `ddr_clk` (CK/4) and `ddr_ck_fast` (CK) come from one PLL with aligned
/// rising edges. If its read leveling fails [Ddr3Controller.defaultMaxCalAttempts]
/// times, the controller stops in a failed state, opens the bus, and raises
/// [Ddr3Controller.calFailed] (STATUS bit 1 in the knob window).
class HarborDdr3 extends BridgeModule
    with
        HarborDeviceTreeNodeProvider,
        HarborSystemMemoryProvider,
        HarborAcpiDeviceProvider,
        HarborSvdPeripheralProvider,
        HarborSimModelProvider {
  final HarborDdrConfig config;
  final int baseAddress;
  final int clockHz;
  final HarborDeviceTarget? target;

  /// DDR CK period in ps (3333 = 300 MHz, the proven Arty S7 x16 point).
  final int ckPeriodPs;

  /// Controller-logic gearing. 1 (default) = the historical CK/4 controller
  /// clocked by `ddr_clk`, no gearbox, byte-identical RTL. 2 = the CK/8
  /// controller: `ddr_clk` becomes CK/8 (the slow, timing-margin logic clock)
  /// and a second `ddr_serdes_clk` input (CK/4) clocks the [Ddr3Phy] and the
  /// interposed [Ddr3ControllerGearbox] that bridges the 128-bit o_phy_*
  /// boundary. The CK/8 + CK/4 clock tree itself is the SoC's job (T4); this
  /// module only consumes the two clocks.
  final int controllerGearRatio;

  /// When true, the controller runs in train=runtime: the PHY calibration
  /// knobs are exposed through an extra SoC-facing wishbone slave [trainBus]
  /// (the wb2 knob-ABI window) and the dtNode gains a `training` child. When
  /// false (default), wb2 stays tied off and dtNode is unchanged from train=hw.
  final bool runtimeTrainable;

  /// ACK a DRAM write on the SoC side as soon as the CDC captures it, instead
  /// of after a full crossing round trip. Set false to A/B the write path on
  /// hardware against the strictly ordered behaviour.
  final bool postedWrites;

  /// Merge sequential narrow writes into one BL8 burst in the burst adapter.
  /// Set false to A/B the write path on hardware.
  final bool writeCombine;

  /// Under Verilator, present the DRAM as a host-side C++ mmap model instead of
  /// a Verilated behavioral RAM. The memory bus is routed to top-level ports and
  /// a [DramStore] drives it, so the whole address space is presented but only
  /// the pages the firmware touches cost host memory. Off by default, so the
  /// standalone sim tests keep the self-contained RTL RAM.
  final bool simExternalMem;

  /// Size of the train (knob-ABI) window in bytes. genip maps it at
  /// baseAddress + config.size - [trainWindowSize].
  static const int trainWindowSize = 0x1000;

  /// The knob-ABI registers are 8-byte strided (a clean 64-bit stride, so the
  /// register index is the byte offset >> [trainStrideLog2]).
  static const int trainStride = 8;
  static const int trainStrideLog2 = 3;

  late final BusSlavePort bus;

  /// The knob-ABI wishbone slave, present only when [runtimeTrainable].
  BusSlavePort? trainBus;

  /// The wrapped controller, exposed for simulation tests.
  Ddr3Controller? controller;

  /// True when [target] is a Lattice ECP5, which builds [Ddr3PhyEcp5].
  bool get isEcp5 => switch (target) {
    HarborFpgaTarget(vendor: HarborFpgaVendor.ecp5) => true,
    _ => false,
  };

  late final DdrParams _p;

  HarborDdr3({
    required this.config,
    required this.baseAddress,
    required this.clockHz,
    this.target,
    int? busAddressWidth,
    int? busDataWidth,
    this.ckPeriodPs = 3333,
    this.controllerGearRatio = 1,
    this.runtimeTrainable = false,
    this.postedWrites = true,
    this.writeCombine = false,
    this.simExternalMem = false,
    super.name = 'ddr3',
  }) : super('HarborDdr3') {
    final clk = addInput('clk', Logic());
    final reset = addInput('reset', Logic());
    final ddrClk = addInput('ddr_clk', Logic());
    final ddrReset = addInput('ddr_reset', Logic());
    // CK/8 controller (gearRatio 2): ddr_clk is the CK/8 logic clock and the
    // SERDES/PHY + gearbox run on a separate CK/4 clock. gearRatio 1 keeps a
    // single clock (no new port), so the elaborated RTL is byte-identical.
    final serdesClk = controllerGearRatio > 1
        ? addInput('ddr_serdes_clk', Logic())
        : ddrClk;
    final ddrCk = addInput('ddr_ck_fast', Logic());
    final ddrCk90 = addInput('ddr_ck90_fast', Logic());
    addInput(
      'ddr_ck_dqs_fast',
      Logic(),
    ); // provided by genip; unused by this PHY
    final idelayRef = addInput('ddr_idelay_ref', Logic());

    final busDW = busDataWidth ?? 32;
    final busAW = busAddressWidth ?? config.size.bitLength;
    bus = BusSlavePort.create(
      module: this,
      name: 'bus',
      protocol: BusProtocol.wishbone,
      addressWidth: busAW,
      dataWidth: busDW,
    );

    if (isEcp5 && controllerGearRatio != 1) {
      throw ArgumentError.value(
        controllerGearRatio,
        'controllerGearRatio',
        'the ECP5 DDR3 PHY needs a CK/4 controller',
      );
    }
    // The ECP5 board is the OrangeCrab r0.2 (MT41K64M16).
    final p = isEcp5
        ? DdrParams.orangeCrab(ckPeriodPs: ckPeriodPs)
        : DdrParams.artyS7(
            ckPeriodPs: ckPeriodPs,
            controllerGearRatio: controllerGearRatio,
          );
    _p = p;

    // Knob-ABI wishbone slave (train=runtime only). SoC (sys clk) facing; a
    // second CDC FIFO crosses it into the DDR clock domain in _build.
    if (runtimeTrainable) {
      trainBus = BusSlavePort.create(
        module: this,
        name: 'train',
        protocol: BusProtocol.wishbone,
        // FULL bus width: the fabric decoder drives every slave the
        // range-relative address AND data at bus width. The wb2 boundary in
        // _build narrows data/sel and converts the word address to the
        // controller's fixed 32-bit / register-index port.
        addressWidth: busAW,
        dataWidth: busDW,
      );
    }

    // Under Verilator there is no PHY, so there are no pads to expose and
    // nothing to drive them. Creating them anyway would leave the bidirectional
    // dq/dqs nets undriven, which is exactly the tristate shape Verilator
    // handles worst.
    if (target is HarborSimTarget) {
      if (simExternalMem) {
        _buildSimExternal(busDW, busAW);
      } else {
        _buildSim(clk, reset, busDW);
      }
      return;
    }

    // SDRAM pads (single-ended SSTL135 + explicit _n complements; matches the
    // legacy Xilinx path so the genip exposePin list is unchanged).
    createPort('sdram_ck', PortDirection.output);
    createPort('sdram_ck_n', PortDirection.output);
    createPort('sdram_cke', PortDirection.output);
    createPort('sdram_cs_n', PortDirection.output);
    createPort('sdram_ras_n', PortDirection.output);
    createPort('sdram_cas_n', PortDirection.output);
    createPort('sdram_we_n', PortDirection.output);
    createPort('sdram_ba', PortDirection.output, width: p.baBits);
    createPort('sdram_addr', PortDirection.output, width: p.rowBits);
    createPort('sdram_dm', PortDirection.output, width: p.lanes);
    createPort('sdram_dq', PortDirection.inOut, width: p.dqBits * p.lanes);
    createPort('sdram_dqs', PortDirection.inOut, width: p.lanes);
    createPort('sdram_dqs_n', PortDirection.inOut, width: p.lanes);
    createPort('sdram_odt', PortDirection.output);
    createPort('sdram_reset_n', PortDirection.output);
    // Self-trained (ECP5) calibration gave up. See [Ddr3Controller.calFailed].
    if (isEcp5) addOutput('cal_failed');

    _build(
      clk,
      reset,
      ddrClk,
      serdesClk,
      ddrReset,
      ddrCk,
      ddrCk90,
      idelayRef,
      p,
      busDW,
      busAW,
    );
  }

  /// Verilator build: a behavioral memory on the same bus port, at the same
  /// base address, with the same device tree. No CDC, no burst adapter, no
  /// controller, no PHY, so no calibration to sit through before the first
  /// access. The timing this drops is exactly the timing Verilator could not
  /// have reproduced anyway.
  void _buildSim(Logic clk, Logic reset, int busDW) {
    final words = usableSize ~/ (busDW ~/ 8);
    final dram = _HarborSimDram(
      addrWidth: bus.addr.width,
      dataWidth: busDW,
      words: words,
      byteSize: usableSize,
    );
    addSubModule(dram);
    dram.input('clk').srcConnection! <= clk;
    dram.input('reset').srcConnection! <= reset;
    dram.input('stb').srcConnection! <= bus.stb;
    dram.input('we').srcConnection! <= bus.we;
    dram.input('adr').srcConnection! <= bus.addr;
    dram.input('dat_w').srcConnection! <= bus.dataIn;
    dram.input('sel').srcConnection! <= bus.sel;
    bus.ack <= dram.output('ack');
    bus.dataOut <= dram.output('dat_r');
  }

  // Set by [_buildSimExternal] for [simModels] to size the host store.
  int? _simBusDW;
  int? _simByteSize;

  /// Verilator with a host-side model: route the wishbone memory bus to
  /// top-level ports so a C++ [DramStore] can be the slave, the same split-port
  /// move the SDIO controller uses under sim. The store mmaps the whole address
  /// space, so only the pages the firmware touches cost host memory. Behaviour
  /// mirrors [_buildSim]: a single-cycle wishbone-B4 slave on the bus clock.
  void _buildSimExternal(int busDW, int busAW) {
    createPort('mem_stb', PortDirection.output);
    createPort('mem_we', PortDirection.output);
    createPort('mem_adr', PortDirection.output, width: busAW);
    createPort('mem_dat_w', PortDirection.output, width: busDW);
    createPort('mem_sel', PortDirection.output, width: busDW ~/ 8);
    createPort('mem_ack', PortDirection.input);
    createPort('mem_dat_r', PortDirection.input, width: busDW);
    output('mem_stb') <= bus.stb;
    output('mem_we') <= bus.we;
    output('mem_adr') <= bus.addr;
    output('mem_dat_w') <= bus.dataIn;
    output('mem_sel') <= bus.sel;
    bus.ack <= input('mem_ack');
    bus.dataOut <= input('mem_dat_r');
    _simBusDW = busDW;
    _simByteSize = usableSize;
  }

  @override
  List<HarborSimModel> simModels(HarborSimModelContext ctx) {
    // Only when the memory bus was routed to the top (simExternalMem, a
    // Verilator build). Otherwise the RTL RAM stands in and there is nothing
    // for a host model to drive.
    final stb = ctx.topPort('mem_stb');
    final we = ctx.topPort('mem_we');
    final adr = ctx.topPort('mem_adr');
    final datW = ctx.topPort('mem_dat_w');
    final sel = ctx.topPort('mem_sel');
    final ack = ctx.topPort('mem_ack');
    final datR = ctx.topPort('mem_dat_r');
    if ([stb, we, adr, datW, sel, ack, datR].any((p) => p == null)) {
      return const [];
    }
    final lanes = (_simBusDW ?? 64) ~/ 8;
    final bytes = _simByteSize ?? usableSize;
    final inst = '${name}_store';
    return [
      HarborSimModel(
        className: 'DramStore',
        // Ticked on the PRIMARY clock (the harness level-gates on the fastest
        // clock), but the bus runs on the peripheral's own domain, so the model
        // is handed that clock and edge-detects it: the handshake must advance
        // once per FABRIC cycle, not once per primary tick, or the ack pulse
        // toggles away before the slower fabric samples it.
        clockPort: ctx.primaryClockPort,
        header: _dramStoreHeader,
        declaration: 'static DramStore $inst("$name", ${bytes}ull, $lanes);',
        tick:
            '$inst.tick(top->${ctx.peripheralClockPort}, top->$stb, '
            'top->$we, top->$adr, top->$datW, top->$sel); '
            'top->$ack = $inst.ack; top->$datR = $inst.dat_r;',
        cliOption:
            'else if (!strncmp(argv[a], "--dram-image=", 13))\n'
            '      $inst.open_image(argv[a] + 13);',
      ),
    ];
  }

  /// The host-side DRAM model. A wishbone-B4 single-cycle slave backed by an
  /// anonymous mmap, so the full address space is presented but only touched
  /// pages are resident. Ticks lockstep with the primary clock (the bus port
  /// runs on it), mirroring the RTL always_ff it stands in for.
  static const _dramStoreHeader = r'''
#pragma once
// Behavioral DRAM for the Verilator harness. Presents the whole address space
// as host memory backed by an anonymous mmap, so only the pages the firmware
// touches cost real memory. Replaces the DDR3 controller + PHY (vendor IP).
//
// A wishbone-B4 single-cycle slave. It mirrors the RTL it stands in for:
//   ack   <= stb & ~ack;   (registered; the master drops stb on the ack)
//   dat_r <= mem[widx];    (registered read, one memory word per access)
// The harness ticks every model on the primary clock (its fastest), but the
// bus runs on the peripheral's own domain, handed in as `clk`. The model
// edge-detects it and advances the handshake once per FABRIC rising edge: the
// primary clock is faster, so a level tick would fire several times per bus
// cycle and toggle the ack pulse away before the fabric ever samples it.
#include <cstdio>
#include <cstdint>
#include <sys/mman.h>

struct DramStore {
  const char* tag;
  uint64_t bytes;   // size of the address space (a power of two)
  int lanes;        // byte lanes in one bus word
  uint8_t* base;    // mmap-backed store, or nullptr on failure
  int prev_clk = 0; // last bus-clock level, for rising-edge detection
  uint8_t ack = 0;  // registered outputs to the bus
  uint64_t dat_r = 0;

  DramStore(const char* t, uint64_t sz, int l) : tag(t), bytes(sz), lanes(l) {
    base = (uint8_t*)mmap(nullptr, bytes, PROT_READ | PROT_WRITE,
                          MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (base == MAP_FAILED) {
      fprintf(stderr, "[dram] %s: mmap of %llu bytes failed\n", tag,
              (unsigned long long)bytes);
      base = nullptr;
    }
  }

  // Load a raw image at the base of the store (offset 0). Optional: the boot
  // firmware is usually a ROM in the RTL, but a DRAM image can be preloaded.
  void open_image(const char* path) {
    if (!base) return;
    FILE* f = fopen(path, "rb");
    if (!f) {
      fprintf(stderr, "[dram] %s: cannot open %s\n", tag, path);
      return;
    }
    size_t n = fread(base, 1, bytes, f);
    fclose(f);
    fprintf(stderr, "[dram] %s: loaded %zu bytes from %s\n", tag, n, path);
  }

  void tick(uint8_t clk, uint8_t stb, uint8_t we, uint64_t adr, uint64_t dat_w,
            uint8_t sel) {
    if (!base) return;
    // Advance only on the bus clock's rising edge, so the handshake matches the
    // fabric cycle rather than the faster primary tick.
    int rising = clk && !prev_clk;
    prev_clk = clk;
    if (!rising) return;
    // Idle: no access, so ack stays low and no stray address faults a page in.
    if (!stb) {
      ack = 0;
      return;
    }
    // ack = stb & ~ack, with stb known 1 here, and the write is gated on the
    // same pre-edge ~ack so a held access writes exactly once.
    uint8_t prev_ack = ack;
    ack = prev_ack ? 0 : 1;
    uint64_t off = (adr & (bytes - 1)) & ~(uint64_t)(lanes - 1);
    uint8_t* word = base + off;
    uint64_t old = 0;
    for (int l = 0; l < lanes; l++) old |= (uint64_t)word[l] << (8 * l);
    if (!prev_ack && we) {
      for (int l = 0; l < lanes; l++)
        if (sel & (1u << l)) word[l] = (dat_w >> (8 * l)) & 0xff;
    }
    dat_r = old;
  }
};
''';

  void _build(
    Logic clk,
    Logic reset,
    Logic ddrClk,
    Logic serdesClk,
    Logic ddrReset,
    Logic ddrCk,
    Logic ddrCk90,
    Logic idelayRef,
    DdrParams p,
    int busDW,
    int busAW,
  ) {
    // Power-on reset on the DDR clock: hold rst_n low for 4096 cycles after the
    // domain reset releases (openXC7 MMCM LOCKED may never reach the fabric), the
    // same guard the standalone harness proved.
    final porCnt = Logic(name: 'ddr_por_cnt', width: 12);
    final rstN = Logic(name: 'ddr_rst_n');
    Sequential(ddrClk, [
      If(
        ddrReset,
        then: [porCnt < Const(0, width: 12), rstN < Const(0)],
        orElse: [
          If(
            porCnt.lt(4095),
            then: [porCnt < porCnt + 1, rstN < Const(0)],
            orElse: [rstN < Const(1)],
          ),
        ],
      ),
    ]);

    // --- CDC: bus-native B4, sys clk -> ddr clk (async gray-pointer FIFO) ---
    final cdc = HarborWishboneCdcFifoBridge(
      addressWidth: busAW,
      dataWidth: busDW,
      selWidth: busDW ~/ 8,
      depth: 16,
      target: target,
      postedWrites: postedWrites,
      name: 'ddr_cdc',
    );
    addSubModule(cdc);
    cdc.input('s_clk').srcConnection! <= clk;
    cdc.input('s_reset').srcConnection! <= reset;
    cdc.input('s_cyc').srcConnection! <= bus.stb;
    cdc.input('s_stb').srcConnection! <= Const(1);
    cdc.input('s_we').srcConnection! <= bus.we;
    cdc.input('s_adr').srcConnection! <= bus.addr;
    cdc.input('s_dat_w').srcConnection! <= bus.dataIn;
    cdc.input('s_sel').srcConnection! <= bus.sel;
    bus.ack <= cdc.output('s_ack');
    bus.dataOut <= cdc.output('s_dat_r');
    cdc.input('m_clk').srcConnection! <= ddrClk;
    cdc.input('m_reset').srcConnection! <= ddrReset;

    // --- burst adapter (32<->128) + controller <-> phy, all on ddr clk ---
    // Placeholder nets break the controller<->adapter<->phy construction cycles.
    final ctrlStall = Logic(name: 'ctrl_stall');
    final ctrlAck = Logic(name: 'ctrl_ack');
    final ctrlData = Logic(name: 'ctrl_data', width: p.wbDataBits);
    final phyData = Logic(
      name: 'phy_iserdes_data',
      width: p.dqBits * p.lanes * 8,
    );
    final phyDqs = Logic(name: 'phy_iserdes_dqs', width: p.lanes * 8);
    final phyBsRef = Logic(name: 'phy_iserdes_bsref', width: p.lanes * 8);
    final phyRdy = Logic(name: 'phy_idelayctrl_rdy');

    final adapter = Ddr3BurstAdapter(
      busAddrWidth: busAW,
      ddrAddrWidth: p.wbAddrBits,
      busDataWidth: busDW,
      ddrDataWidth: p.wbDataBits,
      auxWidth: Ddr3Controller.auxWidth,
      writeCombine: writeCombine,
      clk: ddrClk,
      reset: ddrReset,
      sCyc: cdc.output('m_cyc') & cdc.output('m_stb'),
      sStb: Const(1),
      sWe: cdc.output('m_we'),
      sAddr: cdc.output('m_adr'),
      sData: cdc.output('m_dat_w'),
      sSel: cdc.output('m_sel'),
      mStall: ctrlStall,
      mAck: ctrlAck,
      mData: ctrlData,
    );
    cdc.input('m_ack').srcConnection! <= adapter.output('s_ack');
    cdc.input('m_dat_r').srcConnection! <= adapter.output('s_data_out');

    // --- wb2 knob-ABI window: sys-clk slave -> CDC FIFO -> ddr-clk wb2 ---
    // Placeholder nets break the wb2<->CDC construction cycle (train=runtime).
    Logic wb2Cyc = Const(0);
    Logic wb2Stb = Const(0);
    Logic wb2We = Const(0);
    Logic wb2Addr = Const(0, width: Ddr3Controller.wb2AddrBits);
    Logic wb2Sel = Const(0, width: Ddr3Controller.wb2SelBits);
    Logic wb2Data = Const(0, width: Ddr3Controller.wb2DataBits);
    Logic? wb2Ack;
    Logic? wb2DataOut;
    HarborWishboneCdcFifoBridge? trainCdc;
    if (runtimeTrainable) {
      wb2Ack = Logic(name: 'ctrl_wb2_ack');
      wb2DataOut = Logic(
        name: 'ctrl_wb2_data',
        width: Ddr3Controller.wb2DataBits,
      );
      // The CDC carries the FULL bus width so it matches the fabric decoder.
      // Its width + depth MUST match the main ddr_cdc, so ROHD dedupes both
      // onto one definition (the class hardcodes its definition name; a
      // differing config would collide at synth). Knob writes stay strictly
      // ordered, so this one does not post writes; the class gives a posted
      // bridge a different definition name, so the two do not collide.
      trainCdc = HarborWishboneCdcFifoBridge(
        addressWidth: busAW,
        dataWidth: busDW,
        selWidth: busDW ~/ 8,
        depth: 16,
        target: target,
        name: 'train_cdc',
      );
      addSubModule(trainCdc);
      trainCdc.input('s_clk').srcConnection! <= clk;
      trainCdc.input('s_reset').srcConnection! <= reset;
      trainCdc.input('s_cyc').srcConnection! <= trainBus!.stb;
      trainCdc.input('s_stb').srcConnection! <= Const(1);
      trainCdc.input('s_we').srcConnection! <= trainBus!.we;
      trainCdc.input('s_adr').srcConnection! <= trainBus!.addr;
      trainCdc.input('s_dat_w').srcConnection! <= trainBus!.dataIn;
      trainCdc.input('s_sel').srcConnection! <= trainBus!.sel;
      trainBus!.ack <= trainCdc.output('s_ack');
      // Read data: the controller returns 32 bits; zero-extend to the bus.
      trainBus!.dataOut <= trainCdc.output('s_dat_r').getRange(0, busDW);
      trainCdc.input('m_clk').srcConnection! <= ddrClk;
      trainCdc.input('m_reset').srcConnection! <= ddrReset;

      // --- wb2 boundary adaptation (fabric bus width -> fixed 32b / reg-index) ---
      // ADR: harbor wishbone adr is word-granular (byteOffset >> wordShift).
      // The controller decodes a REGISTER INDEX = byteOffset >> trainStrideLog2.
      // Reconstruct the byte offset from m_adr then divide by the 8-byte stride.
      final wordShift = (busDW ~/ 8).bitLength - 1; // log2(bytesPerWord)
      final mAdr = trainCdc.output('m_adr');
      final byteAddr = wordShift == 0
          ? mAdr
          : [mAdr, Const(0, width: wordShift)].swizzle();
      wb2Addr = byteAddr.getRange(
        trainStrideLog2,
        trainStrideLog2 + Ddr3Controller.wb2AddrBits,
      );

      wb2Cyc = trainCdc.output('m_cyc') & trainCdc.output('m_stb');
      wb2Stb = Const(1);
      wb2We = trainCdc.output('m_we');
      // DATA/SEL: the 32-bit register lives in the low word of the bus word.
      wb2Sel = trainCdc.output('m_sel').getRange(0, Ddr3Controller.wb2SelBits);
      wb2Data = trainCdc
          .output('m_dat_w')
          .getRange(0, Ddr3Controller.wb2DataBits);
      trainCdc.input('m_ack').srcConnection! <= wb2Ack;
      // Zero-extend the 32-bit read response back to the CDC (bus) width.
      trainCdc.input('m_dat_r').srcConnection! <= wb2DataOut.zeroExtend(busDW);
    }

    // A self-training PHY (ECP5) reports its read leveling back.
    final phyLevelDone = isEcp5 ? Logic(name: 'phy_read_level_done') : null;
    final ctrl = Ddr3Controller(
      p,
      controllerClk: ddrClk,
      // ECP5: the controller starts once the PHY can drive the pins (DLL lock
      // and init done), so a late lock cannot use up a calibration try.
      rstN: isEcp5 ? rstN & phyRdy : rstN,
      wbCyc: adapter.output('m_cyc'),
      wbStb: adapter.output('m_stb'),
      wbWe: adapter.output('m_we'),
      wbAddr: adapter.output('m_addr'),
      wbData: adapter.output('m_data_out'),
      wbSel: adapter.output('m_sel'),
      aux: adapter.output('m_aux'),
      wb2Cyc: wb2Cyc,
      wb2Stb: wb2Stb,
      wb2We: wb2We,
      wb2Addr: wb2Addr,
      wb2Sel: wb2Sel,
      wb2Data: wb2Data,
      phyIserdesData: phyData,
      phyIserdesDqs: phyDqs,
      phyIserdesBitslipReference: phyBsRef,
      phyIdelayctrlRdy: phyRdy,
      runtimeTrainable: runtimeTrainable,
      phyReadLevelDone: phyLevelDone,
      phySelfTrainsRead: isEcp5,
      phyReadPipeTicks: isEcp5 ? Ddr3PhyEcp5.readPipeTicks : 0,
    );
    controller = ctrl;
    if (isEcp5) output('cal_failed') <= ctrl.calFailed!;
    ctrlStall <= ctrl.output('o_wb_stall');
    ctrlAck <= ctrl.output('o_wb_ack');
    ctrlData <= ctrl.output('o_wb_data');
    if (runtimeTrainable) {
      wb2Ack! <= ctrl.output('o_wb2_ack');
      wb2DataOut! <= ctrl.output('o_wb2_data');
    }

    // --- inout pads to the PHY (harbor idiom: net through createPort/inOut) ---
    final dqPad = inOut('sdram_dq') as LogicNet;
    final dqsPad = inOut('sdram_dqs') as LogicNet;
    final dqsNPad = inOut('sdram_dqs_n') as LogicNet;

    // gearRatio > 1: the controller runs at CK/8 (ddrClk) and the PHY at CK/4
    // (serdesClk); the gearbox bridges the 128-bit o_phy_* boundary. The command
    // + write data both ride the phase-0 SERDES tick (writeDataPhase 0): the CWL
    // CK separation is produced by the controller's now-gearRatio-aware launch
    // pipeline (STAGE2_DATA_DEPTH halves 2->1 at CK/8, writeSlot unchanged, so
    // controllerClkRatio*depth - writeSlot stays CWL), NOT by a cross-phase
    // gearbox trick (the proven gearbox gates command and DQ on one phase). Phase
    // 1 is always a DESELECT bubble. readCapturePhase 1 is the HW-retuned read
    // window knob (T7). gearRatio 1 keeps the direct controller<->PHY wiring so
    // the RTL is byte-identical.
    final geared = p.gearRatio > 1;
    // Placeholder CK/4 ISERDES returns feed the gearbox at construction (the
    // PHY is built after); only needed when geared, so gearRatio 1 stays
    // byte-identical (direct phy.iserdes* -> controller, no extra net).
    final phyIserRawData = geared
        ? Logic(name: 'phy_iserdes_data_raw', width: p.dqBits * p.lanes * 8)
        : null;
    final phyIserRawDqs = geared
        ? Logic(name: 'phy_iserdes_dqs_raw', width: p.lanes * 8)
        : null;
    final phyIserRawBs = geared
        ? Logic(name: 'phy_iserdes_bsref_raw', width: p.lanes * 8)
        : null;

    Ddr3ControllerGearbox? gb;
    if (geared) {
      gb = Ddr3ControllerGearbox(
        p,
        controllerClk: ddrClk,
        serdesClk: serdesClk,
        rstN: rstN,
        cPhyCmd: ctrl.phyCmd,
        cPhyDqsTriControl: ctrl.output('o_phy_dqs_tri_control'),
        cPhyDqTriControl: ctrl.output('o_phy_dq_tri_control'),
        cPhyToggleDqs: ctrl.output('o_phy_toggle_dqs'),
        cPhyData: ctrl.output('o_phy_data'),
        cPhyDm: ctrl.output('o_phy_dm'),
        cPhyReset: ctrl.phyReset,
        cPhyOdelayDataCntvaluein: ctrl.output('o_phy_odelay_data_cntvaluein'),
        cPhyOdelayDqsCntvaluein: ctrl.output('o_phy_odelay_dqs_cntvaluein'),
        cPhyIdelayDataCntvaluein: ctrl.output('o_phy_idelay_data_cntvaluein'),
        cPhyIdelayDqsCntvaluein: ctrl.output('o_phy_idelay_dqs_cntvaluein'),
        cPhyOdelayDataLd: ctrl.output('o_phy_odelay_data_ld'),
        cPhyOdelayDqsLd: ctrl.output('o_phy_odelay_dqs_ld'),
        cPhyIdelayDataLd: ctrl.output('o_phy_idelay_data_ld'),
        cPhyIdelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
        cPhyBitslip: ctrl.output('o_phy_bitslip'),
        cPhyWriteLevelingCalib: ctrl.output('o_phy_write_leveling_calib'),
        pIserdesData: phyIserRawData!,
        pIserdesDqs: phyIserRawDqs!,
        pIserdesBitslipReference: phyIserRawBs!,
        writeDataPhase: 0,
        readCapturePhase: 1,
      );
    }

    // PHY inputs come from the gearbox (CK/4) when geared, else the controller.
    Logic phyIn(String gbOut, String ctrlOut) =>
        geared ? gb!.output(gbOut) : ctrl.output(ctrlOut);

    // Xilinx 7-series PHY build, shared by every target this stack can
    // serve today. Captured as a closure so the vendor switch below picks
    // a PHY without repeating this argument list per case.
    Ddr3Phy buildXilinxPhy() => Ddr3Phy(
      p,
      controllerClk: serdesClk,
      ddr3Clk: ddrCk,
      refClk: idelayRef,
      ddr3Clk90: ddrCk90,
      rstN: rstN,
      controllerReset: phyIn('o_p_phy_reset', 'o_phy_reset'),
      cmd: phyIn('o_p_phy_cmd', 'o_phy_cmd'),
      dqsTriControl: phyIn('o_p_phy_dqs_tri_control', 'o_phy_dqs_tri_control'),
      dqTriControl: phyIn('o_p_phy_dq_tri_control', 'o_phy_dq_tri_control'),
      toggleDqs: phyIn('o_p_phy_toggle_dqs', 'o_phy_toggle_dqs'),
      data: phyIn('o_p_phy_data', 'o_phy_data'),
      dm: phyIn('o_p_phy_dm', 'o_phy_dm'),
      odelayDataCntValueIn: phyIn(
        'o_p_phy_odelay_data_cntvaluein',
        'o_phy_odelay_data_cntvaluein',
      ),
      odelayDqsCntValueIn: phyIn(
        'o_p_phy_odelay_dqs_cntvaluein',
        'o_phy_odelay_dqs_cntvaluein',
      ),
      idelayDataCntValueIn: phyIn(
        'o_p_phy_idelay_data_cntvaluein',
        'o_phy_idelay_data_cntvaluein',
      ),
      idelayDqsCntValueIn: phyIn(
        'o_p_phy_idelay_dqs_cntvaluein',
        'o_phy_idelay_dqs_cntvaluein',
      ),
      odelayDataLd: phyIn('o_p_phy_odelay_data_ld', 'o_phy_odelay_data_ld'),
      odelayDqsLd: phyIn('o_p_phy_odelay_dqs_ld', 'o_phy_odelay_dqs_ld'),
      idelayDataLd: phyIn('o_p_phy_idelay_data_ld', 'o_phy_idelay_data_ld'),
      idelayDqsLd: phyIn('o_p_phy_idelay_dqs_ld', 'o_phy_idelay_dqs_ld'),
      bitslip: phyIn('o_p_phy_bitslip', 'o_phy_bitslip'),
      writeLevelingCalib: phyIn(
        'o_p_phy_write_leveling_calib',
        'o_phy_write_leveling_calib',
      ),
      dqPad: dqPad,
      dqsPad: dqsPad,
      dqsNPad: dqsNPad,
    );

    // Lattice ECP5 PHY (gearRatio 1 only, so straight from the controller).
    Ddr3PhyEcp5 buildEcp5Phy() => Ddr3PhyEcp5(
      p,
      controllerClk: serdesClk,
      ddr3Clk: ddrCk,
      refClk: idelayRef,
      ddr3Clk90: ddrCk90,
      rstN: rstN,
      controllerReset: ctrl.output('o_phy_reset'),
      cmd: ctrl.output('o_phy_cmd'),
      dqsTriControl: ctrl.output('o_phy_dqs_tri_control'),
      dqTriControl: ctrl.output('o_phy_dq_tri_control'),
      toggleDqs: ctrl.output('o_phy_toggle_dqs'),
      data: ctrl.output('o_phy_data'),
      dm: ctrl.output('o_phy_dm'),
      odelayDataCntValueIn: ctrl.output('o_phy_odelay_data_cntvaluein'),
      odelayDqsCntValueIn: ctrl.output('o_phy_odelay_dqs_cntvaluein'),
      idelayDataCntValueIn: ctrl.output('o_phy_idelay_data_cntvaluein'),
      idelayDqsCntValueIn: ctrl.output('o_phy_idelay_dqs_cntvaluein'),
      odelayDataLd: ctrl.output('o_phy_odelay_data_ld'),
      odelayDqsLd: ctrl.output('o_phy_odelay_dqs_ld'),
      idelayDataLd: ctrl.output('o_phy_idelay_data_ld'),
      idelayDqsLd: ctrl.output('o_phy_idelay_dqs_ld'),
      bitslip: ctrl.output('o_phy_bitslip'),
      writeLevelingCalib: ctrl.output('o_phy_write_leveling_calib'),
      readLevelStart: ctrl.output('o_phy_read_level_start'),
      readLevelCheck: ctrl.output('o_phy_read_level_check'),
      readLevelPass: ctrl.output('o_phy_read_level_pass'),
      readClkSel: runtimeTrainable ? ctrl.output('o_phy_read_clk_sel') : null,
      dqPad: dqPad,
      dqsPad: dqsPad,
      dqsNPad: dqsNPad,
      runtimeTrainable: runtimeTrainable,
      dmRemapping: config.dmRemapping,
    );

    // Pick the PHY by target vendor. iCE40 has no DDR3 PHY in this stack.
    final Ddr3PhyBase phy = switch (target) {
      HarborFpgaTarget(vendor: HarborFpgaVendor.ice40) =>
        throw ArgumentError.value(
          target,
          'target',
          'HarborDdr3 has no DDR3 PHY for iCE40',
        ),
      HarborFpgaTarget(vendor: HarborFpgaVendor.ecp5) => buildEcp5Phy(),
      _ => buildXilinxPhy(),
    };
    if (phyLevelDone != null) phyLevelDone <= phy.readLevelDone!;
    if (geared) {
      // Raw CK/4 ISERDES returns feed the gearbox, which re-times them to CK/8.
      phyIserRawData! <= phy.iserdesData;
      phyIserRawDqs! <= phy.iserdesDqs;
      phyIserRawBs! <= phy.iserdesBitslipReference;
      phyData <= gb!.output('o_c_iserdes_data');
      phyDqs <= gb.output('o_c_iserdes_dqs');
      phyBsRef <= gb.output('o_c_iserdes_bitslip_reference');
    } else {
      // gearRatio 1: direct controller<->PHY (byte-identical to the CK/4 stack).
      phyData <= phy.iserdesData;
      phyDqs <= phy.iserdesDqs;
      phyBsRef <= phy.iserdesBitslipReference;
    }
    phyRdy <= phy.idelayctrlRdy;

    // --- drive the SDRAM control/address pads ---
    output('sdram_ck') <= phy.oDdr3ClkP;
    output('sdram_ck_n') <= phy.oDdr3ClkN;
    output('sdram_cke') <= phy.oDdr3Cke;
    output('sdram_cs_n') <= phy.oDdr3CsN;
    output('sdram_ras_n') <= phy.oDdr3RasN;
    output('sdram_cas_n') <= phy.oDdr3CasN;
    output('sdram_we_n') <= phy.oDdr3WeN;
    output('sdram_ba') <= phy.oDdr3BaAddr;
    output('sdram_addr') <= phy.oDdr3Addr;
    output('sdram_dm') <= phy.oDdr3Dm;
    output('sdram_odt') <= phy.oDdr3Odt;
    output('sdram_reset_n') <= phy.oDdr3ResetN;
  }

  /// Number of DQ byte lanes (dataWidth / 8). Used by the openXC7 DDR
  /// nextpnr pre-place script generator to know how many train SERDES pairs
  /// to pin.
  int get lanes => _p.lanes;

  /// Base of the knob-ABI window: end of the DRAM aperture minus one page.
  int get trainBase => baseAddress + config.size - trainWindowSize;

  /// Usable DRAM span. In train=runtime the top [trainWindowSize] bytes are the
  /// knob-ABI slave (a distinct decoder slot), so they are NOT DRAM: the main
  /// bus mapping + the memory node must exclude them to avoid a decoder overlap.
  int get usableSize =>
      runtimeTrainable ? config.size - trainWindowSize : config.size;

  /// The `training` device-tree child (train=runtime only): geometry-free knob
  /// table + register window that the FSBL sweep engine reads. Reg offsets match
  /// the [Ddr3Controller] wb2 knob-ABI decode; APPLY order = child order.
  HarborDeviceTreeChild get _trainingNode => HarborDeviceTreeChild(
    name: 'training',
    properties: {
      'harbor,train-reg': [trainBase, trainWindowSize],
      'harbor,train-stride': 8,
    },
    children: isEcp5 ? _ecp5Knobs : _xilinxKnobs,
  );

  /// Xilinx knob table (write leveling, write and read taps, bitslip).
  static const _xilinxKnobs = [
    HarborDeviceTreeChild(
      name: 'knob@0',
      properties: {
        'harbor,knob': 'write-level',
        'harbor,reg': [0x00],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'map',
      },
    ),
    HarborDeviceTreeChild(
      name: 'knob@1',
      properties: {
        'harbor,knob': 'write-odelay',
        'harbor,reg': [0x08],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [31],
      },
    ),
    HarborDeviceTreeChild(
      name: 'knob@2',
      properties: {
        'harbor,knob': 'read-idelay',
        'harbor,reg': [0x10],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [31],
      },
    ),
    HarborDeviceTreeChild(
      name: 'knob@3',
      properties: {
        'harbor,knob': 'bitslip',
        'harbor,reg': [0x18],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [7],
      },
    ),
  ];

  /// ECP5 knob table. ECP5 has no write taps and is not write leveled. Read
  /// leveling is a 2D search (bitslip outer, read clock select inner, as the
  /// LiteX BIOS does), then the DELAYF read tap.
  static const _ecp5Knobs = [
    HarborDeviceTreeChild(
      name: 'knob@3',
      properties: {
        'harbor,knob': 'bitslip',
        'harbor,reg': [0x18],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [15],
      },
    ),
    HarborDeviceTreeChild(
      name: 'knob@7',
      properties: {
        'harbor,knob': 'read-clk-sel',
        'harbor,reg': [0x38],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [7],
      },
    ),
    HarborDeviceTreeChild(
      name: 'knob@2',
      properties: {
        'harbor,knob': 'read-idelay',
        'harbor,reg': [0x10],
        'harbor,scope': 'per-lane',
        'harbor,feedback': 'pattern',
        'harbor,min': [0],
        'harbor,max': [31],
      },
    ),
  ];

  @override
  HarborDeviceTreeNode get dtNode => HarborDeviceTreeNode(
    compatible: [
      'harbor,sdram-controller',
      if (config.type == HarborDdrType.ddr3 ||
          config.type == HarborDdrType.ddr3l)
        'harbor,ddr3-sdram',
    ],
    reg: BusAddressRange(baseAddress, usableSize),
    properties: {
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
      if (runtimeTrainable) ...{
        'harbor,ddr-rows': _p.rowBits,
        'harbor,ddr-cols': _p.colBits,
        'harbor,ddr-banks': 1 << _p.baBits,
        'harbor,ddr-ranks': _p.dualRankDimm ? 2 : 1,
        'harbor,ddr-lanes': _p.lanes,
      },
    },
    children: [if (runtimeTrainable) _trainingNode],
  );

  @override
  List<BusAddressRange> get systemMemory => [
    BusAddressRange(baseAddress, usableSize),
  ];

  @override
  HarborAcpiDevice get acpiDevice => HarborAcpiDevice(
    hid: 'PRP0001',
    uid: 0,
    memory: [BusAddressRange(baseAddress, usableSize)],
    properties: {
      'compatible': [
        'harbor,sdram-controller',
        if (config.type == HarborDdrType.ddr3 ||
            config.type == HarborDdrType.ddr3l)
          'harbor,ddr3-sdram',
      ],
      'sdram-type': config.type.name,
      'data-width': config.dataWidth,
      'clock-frequency': config.frequency,
    },
  );

  @override
  HarborSvdPeripheral get svdPeripheral => HarborSvdPeripheral(
    name: 'DDR',
    groupName: 'DDR',
    description: 'SDRAM memory controller (Ddr3Controller)',
    baseAddress: baseAddress,
    size: config.size,
  );
}

/// Behavioral DRAM leaf for the Verilator build. Carries its own SystemVerilog
/// body so the ports and the module they must match live in one place.
class _HarborSimDram extends BridgeModule with HarborSimLeaf {
  final int addrWidth;
  final int dataWidth;
  final int words;
  final int byteSize;

  _HarborSimDram({
    required this.addrWidth,
    required this.dataWidth,
    required this.words,
    required this.byteSize,
  }) : super('harbor_sim_dram', name: 'sim_dram', isSystemVerilogLeaf: true) {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('stb', PortDirection.input);
    createPort('we', PortDirection.input);
    createPort('adr', PortDirection.input, width: addrWidth);
    createPort('dat_w', PortDirection.input, width: dataWidth);
    createPort('sel', PortDirection.input, width: dataWidth ~/ 8);
    addOutput('ack');
    addOutput('dat_r', width: dataWidth);
  }

  @override
  String get simRtl {
    final dw = dataWidth;
    final aw = addrWidth;
    final lanes = dw ~/ 8;
    final byteBits = (lanes - 1).bitLength;
    final idxBits = (words - 1).bitLength;
    final b = StringBuffer();
    b.writeln('// Auto-generated behavioral DRAM for the Verilator build.');
    b.writeln('// Replaces the DDR3 controller + PHY, which are vendor IP.');
    b.writeln('//');
    b.writeln('// Preload a boot image with a plusarg, e.g.');
    b.writeln('//   ./obj_dir/Vtop +dram_image=fw.hex');
    b.writeln('// where fw.hex is one $dw-bit word per line in hex');
    b.writeln('// (objcopy -O verilog, or hexdump).');
    b.writeln('module $definitionName (');
    b.writeln('  input  logic            clk,');
    b.writeln('  input  logic            reset,');
    b.writeln('  input  logic            stb,');
    b.writeln('  input  logic            we,');
    b.writeln('  input  logic [${aw - 1}:0] adr,');
    b.writeln('  input  logic [${dw - 1}:0] dat_w,');
    b.writeln('  input  logic [${lanes - 1}:0]  sel,');
    b.writeln('  output logic            ack,');
    b.writeln('  output logic [${dw - 1}:0] dat_r');
    b.writeln(');');
    b.writeln('  // $words words of $dw bits ($byteSize bytes).');
    b.writeln('  logic [${dw - 1}:0] mem [0:${words - 1}];');
    b.writeln(
      '  wire [${idxBits - 1}:0] widx = adr[${idxBits + byteBits - 1}:'
      '$byteBits];',
    );
    b.writeln();
    b.writeln('  string image;');
    b.writeln('  initial begin');
    b.writeln('    if (\$value\$plusargs("dram_image=%s", image))');
    b.writeln('      \$readmemh(image, mem);');
    b.writeln('  end');
    b.writeln();
    b.writeln(
      '  // Single-cycle ACK. The bus master must drop STB on the ACK,',
    );
    b.writeln('  // so `ack` is gated on its own previous value.');
    b.writeln('  always_ff @(posedge clk) begin');
    b.writeln('    if (reset) begin');
    b.writeln("      ack <= 1'b0;");
    b.writeln('    end else begin');
    b.writeln('      ack <= stb & ~ack;');
    b.writeln('      if (stb & ~ack & we) begin');
    for (var l = 0; l < lanes; l++) {
      b.writeln(
        '        if (sel[$l]) mem[widx][${l * 8 + 7}:${l * 8}] '
        '<= dat_w[${l * 8 + 7}:${l * 8}];',
      );
    }
    b.writeln('      end');
    b.writeln('      dat_r <= mem[widx];');
    b.writeln('    end');
    b.writeln('  end');
    b.writeln('endmodule');
    return b.toString();
  }
}
