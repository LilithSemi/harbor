import 'dart:math';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';
import 'package:test/test.dart';

import '../bus/port/memory_harness.dart';
import '../bus/port/port_harness.dart';
import 'memory_port_bench.dart';

const _spartan7 = HarborFpgaTarget.spartan7(device: 's50', package: 'csga324');

const _config = HarborMemoryWaistConfig(
  addressWidth: 14,
  dataWidth: 32,
  idWidth: 2,
  outstanding: 2,
);

/// A requester linked to a Spartan-7 [HarborSram] of [size] bytes.
class _Bench extends BridgeModule {
  late final HarborSram sram;

  _Bench(int size) : super('SramXilinxBench_$size', name: 'top') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    sram = addSubModule(
      HarborSram(
        baseAddress: 0,
        size: size,
        protocol: HarborFabricKind.axi4,
        idWidth: _config.idWidth,
        busAddressWidth: _config.addressWidth,
        target: _spartan7,
      ),
    );
    sram.input('clk').srcConnection! <= input('clk');
    sram.input('reset').srcConnection! <= input('reset');
    linkRequester(this, sram, _config, HarborFabricKind.axi4);
  }
}

/// A port A model of one RAMB36E1 in x36 mode with WRITE_FIRST, as the
/// blackbox has no behaviour in simulation. It holds 1024 words of 32 bits.
class _Ramb36Model {
  final words = List<int>.filled(1024, 0);

  _Ramb36Model(Module bram, Logic clk) {
    Logic sample(String port, int width) {
      final q = Logic(name: '${bram.name}_$port', width: width);
      Sequential(clk, [q < bram.input(port)]);
      return q;
    }

    final en = sample('ENARDEN', 1);
    final we = sample('WEA', 4);
    final addr = sample('ADDRARDADDR', 16);
    final di = sample('DIADI', 32);
    final out = bram.output('DOADO');
    out.put(0);
    // ROHD sends posedge after the Sequential, so the samples hold the
    // inputs from before the edge.
    clk.posedge.listen((_) {
      if (!en.value.isValid || !en.value.toBool()) return;
      final word = (addr.value.toInt() >> 5) & 1023;
      final wea = we.value.toInt();
      if (wea != 0) {
        final data = di.value.toInt();
        var next = words[word];
        for (var b = 0; b < 4; b++) {
          if ((wea >> b) & 1 == 0) continue;
          final mask = 0xff << (8 * b);
          next = (next & ~mask) | (data & mask);
        }
        words[word] = next;
      }
      out.put(LogicValue.ofInt(words[word], 32));
    });
  }
}

Iterable<Module> _all(Module m) sync* {
  for (final s in m.subModules) {
    yield s;
    yield* _all(s);
  }
}

void main() {
  tearDown(endAndReset);

  for (final banks in [3, 4]) {
    test('$banks banks: every bank reads back its own words', () async {
      final size = banks * 4096;
      final bench = _Bench(size);
      final s = Sim(bench);
      final check = MemoryPortCheck(
        s,
        Random(banks),
        busBytes: 4,
        idWidth: _config.idWidth,
        span: size,
      );
      await s.start();
      final brams = {
        for (final m in _all(bench.sram))
          if (m is XilinxRamb36e1) m.name: _Ramb36Model(m, s.clk),
      };
      expect(brams.keys.toSet(), {
        for (var d = 0; d < banks; d++) 'bram_${d}_0',
      });
      Simulator.setMaxSimTime(40000000);
      await check.fill();
      final bad = await check.run(8);
      await s.stop();
      expect(bad, isEmpty);
      // Each word is in the bank that its address selects.
      for (var d = 0; d < banks; d++) {
        final words = brams['bram_${d}_0']!.words;
        for (var i = 0; i < 1024; i++) {
          expect(
            words[i],
            check.want.read((d * 1024 + i) * 4),
            reason: 'bank $d word $i',
          );
        }
      }
    });
  }
}
