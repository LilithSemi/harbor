import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../../bin/gen_ax7203_pcie_gpu.dart' hide main;

void main() {
  test(
    'AX7203 PCIe GPU build has every block and enforced timing',
    () async {
      final dir = Directory.systemTemp.createTempSync('harbor_ax7203_gpu_');
      addTearDown(() async {
        dir.deleteSync(recursive: true);
        await Simulator.reset();
      });
      await generateAx7203PcieGpu(dir);

      final rtl = Directory('${dir.path}/rtl')
          .listSync()
          .whereType<File>()
          .map((f) => f.readAsStringSync())
          .join('\n');
      final top = File('${dir.path}/rtl/Ax7203PcieGpu.sv').readAsStringSync();
      for (final module in [
        'HarborPcieEndpoint_Xilinx7_X1_Pm1024_Bar2x1000000_Msi2',
        'HarborPcieRouter_W64_dma_4c_mem_10n_rom_100n',
        'HarborPcieDma_W64_D64_A24_axi4_Sfr_',
        'HarborPcieMemoryCompleter_W64_D64_A24_axi4_S1000000_O0_B4_P256',
        'HarborPcieOptionRom_W64_S262144_O12582912_A24_wishbone',
        'HarborSpiFlashController_',
        'HarborSram_16384_d64_a24_axi4_',
      ]) {
        expect(top, contains(module));
      }
      expect(rtl, contains('PCIE_2_1'));
      // The option ROM counters reset only on the power on reset.
      expect(top, contains('por_count'));
      expect(top, contains('.counter_reset('));
      expect(top, contains('.rom_status('));
      // The reset counters count PERST# on the board clock and reach BAR0.
      expect(top, contains('.reset_status('));
      expect(top, contains('.free_clk('));
      expect(rtl, contains(RegExp(r'HarborPcieInterrupt\s+pcie_interrupt')));
      expect(rtl, contains(".MSI_CAP_MULTIMSGCAP(1)"));
      expect(rtl, contains(".irq_pending(irq_pending)"));

      final xdc = File('${dir.path}/Ax7203PcieGpu.xdc').readAsStringSync();
      expect(xdc, contains('set_property LOC PCIE_X0Y0'));
      expect(xdc, contains('set_property LOC GTPE2_CHANNEL_X0Y5'));
      expect(
        xdc,
        contains('pipe_clock.userclk1}]'),
        reason: 'the user clock has a 62.5 MHz target',
      );
      expect(xdc, contains('[get_ports pcie_rxp]'));
      final mk = File('${dir.path}/Makefile').readAsStringSync();
      expect(mk, contains('nextpnr-himbaechel'));
      expect(mk, contains(r'$(PNRTIMING) $(PNRFLAGS)'));
      expect(
        File('${dir.path}/support/nextpnr/clocks.py').existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
