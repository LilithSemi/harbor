// AX7203 PCIe GPU build: the endpoint with the router, the DMA engine, the
// BAR2 memory completer, the option ROM and MSI, on the PCIe user clock.
//
// Usage: dart run bin/gen_ax7203_pcie_gpu.dart <out dir>
//
// The out dir gets rtl/, the XDC, synth.tcl and the Makefile of the openXC7
// Himbächel flow. Run `make all PNRFLAGS=--chipdb <chipdb-xc7a200t.bin>`.
// The Makefile adds the placer flags in PNRTIMING.
// The DMA and the completer each have a 16 KB block RAM as local memory.
import 'dart:io';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Timing and placement of the endpoint on the AX7203.
const ax7203PcieConstraints = [
  'create_clock -period 10 [get_ports {pcie_refclk_p}]',
  'create_clock -period 10 [get_nets {pcie_endpoint.pcie_phy.gt0_TXOUTCLK}]',
  'create_clock -period 8 '
      '[get_nets {pcie_endpoint.pcie_phy.gtp_pcie_phy.pipe_clock.pclk}]',
  'create_clock -period 16 '
      '[get_nets {pcie_endpoint.pcie_phy.gtp_pcie_phy.pipe_clock.userclk1}]',
  'set_property LOC GTPE2_CHANNEL_X0Y5 '
      '[get_cells {pcie_endpoint.pcie_phy.pcie_gtp_channel}]',
  'set_property LOC GTPE2_COMMON_X0Y1 '
      '[get_cells {pcie_endpoint.pcie_phy.pcie_gtp_common}]',
  'set_property LOC IBUFDS_GTE2_X0Y3 '
      '[get_cells {pcie_endpoint.pcie_phy.pcie_refclk_buffer}]',
  'set_property LOC PCIE_X0Y0 [get_cells {pcie_endpoint.pcie_hard_block}]',
];

const ax7203LocalBytes = 16 * 1024;
const ax7203LocalAddressWidth = 24;
const ax7203OptionRomOffset = 0xc00000;
const ax7203OptionRomBytes = 256 * 1024;
const ax7203InfoWords = [0x47504755, 0x00000001];
const ax7203IrqLines = 1;
const ax7203MsiVectors = 2;

class Ax7203PcieGpu extends BridgeModule {
  late final HarborPcieEndpoint endpoint;
  late final HarborPcieDma dma;
  late final HarborPcieMemoryCompleter completer;
  late final HarborPcieOptionRom rom;

  Ax7203PcieGpu(HarborFpgaTarget target)
    : super('Ax7203PcieGpu', name: 'ax7203_pcie_gpu') {
    // Vector 0 is the DMA and vector 1 + i is line i. With fewer vectors,
    // every group falls back to vector 0.
    if (ax7203MsiVectors < 1 + ax7203IrqLines) {
      throw ArgumentError('msiVectors must be at least 1 + irqLines');
    }
    final refClkP = createPort('pcie_refclk_p', PortDirection.input).port;
    final refClkN = createPort('pcie_refclk_n', PortDirection.input).port;
    final perstN = createPort('pcie_perst_n', PortDirection.input).port;
    final rxP = createPort('pcie_rxp', PortDirection.input).port;
    final rxN = createPort('pcie_rxn', PortDirection.input).port;
    final keyN = createPort('key_n', PortDirection.input, width: 2).port;

    final up = HarborPcieStream(width: 64, name: 'ep_rx');
    final down = HarborPcieStream(width: 64, name: 'ep_tx');
    final irqPending = Logic(name: 'irq_pending', width: 8);
    endpoint = HarborPcieEndpoint(
      target: target,
      refClkP: refClkP,
      refClkN: refClkN,
      perstN: perstN,
      rxP: rxP,
      rxN: rxN,
      rxReady: up.ready,
      txData: down.data,
      txKeep: down.keep,
      txLast: down.last,
      txValid: down.valid,
      irqPending: irqPending,
      config: const HarborPcieEndpointConfig(
        classCode: 0x038000,
        packetMemoryEntries: 1024,
        optionRomBytes: ax7203OptionRomBytes,
        bar2Bytes: 16 << 20,
        msiVectors: ax7203MsiVectors,
      ),
    );
    up.data <= endpoint.rxData;
    up.keep <= endpoint.rxKeep;
    up.last <= endpoint.rxLast;
    up.valid <= endpoint.rxValid;
    up.user <= endpoint.rxUser;
    down.ready <= endpoint.txReady;
    addOutput('pcie_txp') <= endpoint.txP;
    addOutput('pcie_txn') <= endpoint.txN;

    final clk = endpoint.userClk;
    final reset = endpoint.userReset;

    // KEY1 is the SoC interrupt line, active low.
    final keySync = [Logic(name: 'key_sync0'), Logic(name: 'key_sync1')];
    Sequential(clk, [keySync[0] < ~keyN[0], keySync[1] < keySync[0]]);

    HarborPcieStream s(String n) => HarborPcieStream(width: 64, name: n);
    final dmaRx = s('dma_rx');
    final dmaTx = s('dma_tx');
    final memRx = s('mem_rx');
    final memTx = s('mem_tx');
    final romRx = s('rom_rx');
    final romTx = s('rom_tx');

    dma = addSubModule(
      HarborPcieDma(
        clk: clk,
        reset: reset,
        completerId: endpoint.completerId,
        maxPayload: endpoint.maxPayload,
        maxReadRequest: endpoint.maxReadRequest,
        rcb128: endpoint.rcb128,
        busMasterEnable: endpoint.busMasterEnable,
        msiEnable: endpoint.msiEnable,
        msiVectorsGranted: endpoint.msiVectorsGranted,
        rx: dmaRx,
        tx: dmaTx,
        irqInputs: keySync[1],
        addressWidth: ax7203LocalAddressWidth,
        ringSource: true,
        irqLines: ax7203IrqLines,
        infoWords: ax7203InfoWords,
      ),
    );
    irqPending <= dma.irqPending;
    completer = addSubModule(
      HarborPcieMemoryCompleter(
        clk: clk,
        reset: reset,
        maxPayload: endpoint.maxPayload,
        rcb128: endpoint.rcb128,
        completerId: endpoint.completerId,
        rx: memRx,
        tx: memTx,
        addressWidth: ax7203LocalAddressWidth,
      ),
    );
    rom = addSubModule(
      HarborPcieOptionRom(
        clk: clk,
        reset: reset,
        completerId: endpoint.completerId,
        rx: romRx,
        tx: romTx,
        romSize: ax7203OptionRomBytes,
        memoryOffset: ax7203OptionRomOffset,
        memoryAddressWidth: 24,
        readCompletionBoundary128: endpoint.rcb128,
      ),
    );
    HarborPcieRouter(
      clk: clk,
      reset: reset,
      width: 64,
      completerId: endpoint.completerId,
      upstreamRx: up,
      upstreamTx: down,
      clients: [
        HarborPcieRouterClient(
          name: 'dma',
          barMask: HarborPcieStream.userBar0,
          rx: dmaRx,
          tx: dmaTx,
          takesCompletions: true,
        ),
        HarborPcieRouterClient(
          name: 'mem',
          barMask: HarborPcieStream.userBar2,
          rx: memRx,
          tx: memTx,
        ),
        HarborPcieRouterClient(
          name: 'rom',
          barMask: HarborPcieStream.userRom,
          rx: romRx,
          tx: romTx,
        ),
      ],
    );

    for (final (n, master) in [('dma', dma), ('mem', completer)]) {
      final sram = addSubModule(
        HarborSram(
          baseAddress: 0,
          size: ax7203LocalBytes,
          dataWidth: 64,
          busAddressWidth: ax7203LocalAddressWidth,
          protocol: HarborFabricKind.axi4,
          target: target,
          name: '${n}_sram',
        ),
      );
      sram.input('clk').srcConnection! <= clk;
      sram.input('reset').srcConnection! <= reset;
      connectInterfaces(master.interface('memory'), sram.interface('bus'));
    }

    final flash = addSubModule(
      HarborSpiFlashController(
        config: const HarborSpiFlashConfig.w25q128(),
        baseAddress: 0,
        busAddressWidth: 24,
        useStartupe2: true,
        ownPads: true,
      ),
    );
    flash.input('clk').srcConnection! <= clk;
    flash.input('reset').srcConnection! <= reset;
    flash.input('wr_req').srcConnection! <= Const(0);
    flash.input('wr_op').srcConnection! <= Const(0);
    flash.input('wr_addr').srcConnection! <= Const(0, width: 24);
    flash.input('wr_len').srcConnection! <= Const(0, width: 9);
    flash.input('wr_data').srcConnection! <= Const(0, width: 8);
    connectInterfaces(rom.interface('memory'), flash.interface('bus'));
    pullUpPort(flash.port('spi_cs_n'), newPortName: 'spi_cs_n');
    pullUpPort(flash.port('spi_io'), newPortName: 'spi_io');

    addOutput('led_n', width: 4) <=
        ~[
          irqPending.or(),
          endpoint.msiEnable,
          endpoint.busMasterEnable,
          endpoint.linkUp,
        ].swizzle();
  }
}

/// The AX7203 target with lane 0 of the PCIe connector as a 1 bit port.
HarborFpgaTarget ax7203PcieTarget() {
  final board = HarborBoard.get('ax7203');
  return board.fpgaTarget(
    pins: [
      'pcie_refclk_p',
      'pcie_refclk_n',
      'pcie_perst_n',
      for (var i = 0; i < 4; i++) 'led_n[$i]',
      'key_n[0]',
      'key_n[1]',
      'spi_cs_n',
      for (var i = 0; i < 4; i++) 'spi_io[$i]',
    ],
    frequency: 0,
    extraPins: {
      for (final p in ['pcie_rxp', 'pcie_rxn', 'pcie_txp', 'pcie_txn'])
        p: board.pins['$p[0]']!,
    },
    useHimbaechel: true,
  );
}

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: gen_ax7203_pcie_gpu.dart <out dir>');
    exit(2);
  }
  final files = await generateAx7203PcieGpu(Directory(args.single));
  stdout.writeln('wrote $files files to ${args.single}');
}

/// Writes the build of [Ax7203PcieGpu] to [dir]. Returns the RTL file count.
Future<int> generateAx7203PcieGpu(Directory dir) async {
  dir.createSync(recursive: true);
  final target = ax7203PcieTarget();
  final top = Ax7203PcieGpu(target);
  await top.build();

  final rtl = Directory('${dir.path}/rtl')..createSync(recursive: true);
  final svFiles = <String>[];
  for (final f in SynthBuilder(
    top,
    SystemVerilogSynthesizer(),
  ).getSynthFileContents()) {
    var contents = f.contents;
    // yosys rejects the two ports named `w` of the ROHD net_connect helper.
    if (f.name == 'net_connect') {
      contents =
          'module net_connect #(parameter int WIDTH=1) (w0, w1);\n'
          'inout wire [WIDTH-1:0] w0;\n'
          'inout wire [WIDTH-1:0] w1;\n'
          'assign w0 = w1;\n'
          'assign w1 = w0;\n'
          'endmodule\n';
    }
    File('${rtl.path}/${f.name}.sv').writeAsStringSync(contents);
    svFiles.add('rtl/${f.name}.sv');
  }
  svFiles.sort();
  final name = top.definitionName;
  final knownPorts = {
    ...top.inputs.keys,
    ...top.outputs.keys,
    ...top.inOuts.keys,
  };
  final missing = target.missingPins({
    for (final p in [
      ...top.inputs.values,
      ...top.outputs.values,
      ...top.inOuts.values,
    ])
      p.name: p.width,
  });
  if (missing.isNotEmpty) {
    throw StateError('ports without a pin: ${missing.join(', ')}');
  }
  File('${dir.path}/$name.xdc').writeAsStringSync(
    target.generateConstraints(
      knownPorts: knownPorts,
      deviceLines: ax7203PcieConstraints,
    ),
  );
  File(
    '${dir.path}/synth.tcl',
  ).writeAsStringSync(target.generateYosysTcl(name, svFiles: svFiles));
  // The default heap placement leaves the router with hot spots and the
  // user clock fails. Congestion spreading and timing ripup close it.
  final makefile = target
      .generateMakefile(name)
      .replaceFirst(
        'PNRFLAGS ?=\n',
        'PNRFLAGS ?=\n'
            'PNRTIMING ?= --placer-heap-congestion-spread --tmg-ripup\n',
      )
      .replaceFirst(r'$(PNRFLAGS)', r'$(PNRTIMING) $(PNRFLAGS)');
  File('${dir.path}/Makefile').writeAsStringSync(makefile);
  return svFiles.length;
}
