import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

// Register word indices (bus presents a word index).
const _ctrl = 0x00;
const _status = 0x08;
const _linkCtrl = 0x10;
const _intStatus = 0x18;
const _intEnable = 0x20;
const _msiAddr = 0x80;
const _msiData = 0x88;
const _msiPend = 0x98;
const _tlpAddrLo = 0xA0;
const _tlpAddrHi = 0xA8;
const _tlpLen = 0xB0;
const _tlpCtrl = 0xB8;
const _tlpData = 0xC0;
const _tlpStatus = 0xC8;
const _tlpHdr0 = 0xD0;
const _tlpHdr2 = 0xE0;
const _msiTrigger = 0xE8;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('HarborPcieController config', () {
    test('bandwidth and pretty string', () {
      const c = HarborPcieConfig(
        maxGen: HarborPcieGen.gen3,
        maxLanes: HarborPcieLanes.x4,
      );
      expect(c.totalBandwidthMBs, closeTo(984.6 * 4, 1));
      expect(c.toPrettyString(), contains('gen: 3'));
    });

    test('DT node is an ECAM host bridge', () {
      final pcie = HarborPcieController(
        config: const HarborPcieConfig(),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      final dt = pcie.dtNode;
      expect(dt.compatible, contains('pci-host-ecam-generic'));
      expect(dt.properties['max-link-speed'], equals(3));
      expect(dt.properties['num-lanes'], equals(4));
    });
  });

  group('HarborPcieController LTSSM', () {
    late HarborPcieController pcie;
    late Logic clk, reset, stb, we, adr, mosi, rxn0;
    late Logic estb, ewe, eadr, emosi;
    late List<Logic> mem; // downstream memory model (endpoint), 16 words

    // Builds an ECAM dword address from bus/dev/fn and a register byte offset.
    int ecamAddr(int bus, int dev, int fn, int regByte) =>
        (bus << 18) | (dev << 13) | (fn << 10) | (regByte >> 2);

    Future<void> ew(int addr, int data) async {
      eadr.inject(addr);
      emosi.inject(data);
      ewe.inject(1);
      estb.inject(1);
      await clk.nextPosedge;
      while (pcie.output('ecam_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      estb.inject(0);
      ewe.inject(0);
      await clk.nextPosedge;
    }

    Future<int> er(int addr) async {
      eadr.inject(addr);
      ewe.inject(0);
      estb.inject(1);
      await clk.nextPosedge;
      while (pcie.output('ecam_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = pcie.output('ecam_DAT_MISO').value.toInt();
      estb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> bw(int addr, int data) async {
      adr.inject(addr);
      mosi.inject(data);
      we.inject(1);
      stb.inject(1);
      await clk.nextPosedge;
      while (pcie.output('bus_ACK').value.toInt() != 1) {
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
      while (pcie.output('bus_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = pcie.output('bus_DAT_MISO').value.toInt();
      stb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    Future<void> setUpDut() async {
      pcie = HarborPcieController(
        config: const HarborPcieConfig(
          maxGen: HarborPcieGen.gen3,
          maxLanes: HarborPcieLanes.x4,
        ),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      stb = Logic(name: 'stb');
      we = Logic(name: 'we');
      adr = Logic(name: 'adr', width: 12);
      mosi = Logic(name: 'mosi', width: 32);
      rxn0 = Logic(name: 'rxn0');
      estb = Logic(name: 'estb');
      ewe = Logic(name: 'ewe');
      eadr = Logic(name: 'eadr', width: 26);
      emosi = Logic(name: 'emosi', width: 32);

      pcie.input('clk').srcConnection! <= clk;
      pcie.input('reset').srcConnection! <= reset;
      pcie.input('wake_n').srcConnection! <= Const(1);
      pcie.input('rxn_0').srcConnection! <= rxn0;
      pcie.input('rxp_0').srcConnection! <= Const(0);
      for (var i = 1; i < 4; i++) {
        pcie.input('rxp_$i').srcConnection! <= Const(0);
        pcie.input('rxn_$i').srcConnection! <= Const(1);
      }
      pcie.input('bus_CYC').srcConnection! <= stb;
      pcie.input('bus_STB').srcConnection! <= stb;
      pcie.input('bus_WE').srcConnection! <= we;
      pcie.input('bus_ADR').srcConnection! <= adr;
      pcie.input('bus_DAT_MOSI').srcConnection! <= mosi;
      pcie.input('bus_SEL').srcConnection! <=
          Const(0xF, width: pcie.input('bus_SEL').width);
      pcie.input('ecam_CYC').srcConnection! <= estb;
      pcie.input('ecam_STB').srcConnection! <= estb;
      pcie.input('ecam_WE').srcConnection! <= ewe;
      pcie.input('ecam_ADR').srcConnection! <= eadr;
      pcie.input('ecam_DAT_MOSI').srcConnection! <= emosi;
      pcie.input('ecam_SEL').srcConnection! <=
          Const(0xF, width: pcie.input('ecam_SEL').width);

      // Downstream memory model backing the master port (the endpoint). Single
      // cycle ack=stb, combinational read mux, clocked write, preset on reset.
      mem = List.generate(16, (i) => Logic(name: 'mem_$i', width: 32));
      final mAddr = pcie.output('pcie_m_addr');
      final mWdata = pcie.output('pcie_m_wdata');
      final mWe = pcie.output('pcie_m_we');
      final mStb = pcie.output('pcie_m_stb');
      final wordIdx = mAddr.getRange(2, 6); // word index for 0x00..0x3C
      Logic rd = Const(0, width: 32);
      for (var i = 15; i >= 0; i--) {
        rd = mux(wordIdx.eq(Const(i, width: 4)), mem[i], rd);
      }
      pcie.input('pcie_m_rdata').srcConnection! <= rd;
      pcie.input('pcie_m_ack').srcConnection! <= mStb;
      Sequential(clk, [
        If(
          reset,
          then: [
            for (var i = 0; i < 16; i++) mem[i] < Const(0xAA00 + i, width: 32),
          ],
          orElse: [
            If(
              mStb & mWe,
              then: [
                for (var i = 0; i < 16; i++)
                  If(wordIdx.eq(Const(i, width: 4)), then: [mem[i] < mWdata]),
              ],
            ),
          ],
        ),
      ]);

      await pcie.build();
      reset.inject(1);
      stb.inject(0);
      we.inject(0);
      adr.inject(0);
      mosi.inject(0);
      rxn0.inject(1); // partner attached
      estb.inject(0);
      ewe.inject(0);
      eadr.inject(0);
      emosi.inject(0);
      Simulator.setMaxSimTime(10000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    // Polls STATUS until link_up, returns the STATUS word (0 if it never came).
    Future<int> waitLinkUp({int cycles = 80}) async {
      for (var i = 0; i < cycles; i++) {
        final s = await br(_status);
        if (s & 0x1 == 0x1) return s;
      }
      return 0;
    }

    test('trains from Detect to L0 and reports link up', () async {
      await setUpDut();
      await bw(_ctrl, 0x1); // enable
      final status = await waitLinkUp();
      expect(status & 0x1, equals(0x1), reason: 'link up');
      expect((status >> 4) & 0x7, equals(3), reason: 'negotiated Gen3');
      expect((status >> 8) & 0x1F, equals(4), reason: 'negotiated x4');
      expect((status >> 16) & 0x7, equals(3), reason: 'LTSSM in L0');
      expect((await br(_intStatus)) & 0x1, equals(0x1), reason: 'link-up int');
      await Simulator.endSimulation();
    });

    test('drops the link when the partner detaches', () async {
      await setUpDut();
      await bw(_ctrl, 0x1);
      expect((await waitLinkUp()) & 0x1, equals(0x1));
      // Clear the link-up interrupt, then detach the partner.
      await bw(_intStatus, 0x1);
      rxn0.inject(0);
      var down = 0;
      for (var i = 0; i < 40; i++) {
        if ((await br(_status)) & 0x1 == 0) {
          down = 1;
          break;
        }
      }
      expect(down, equals(1), reason: 'link dropped');
      expect(
        (await br(_intStatus)) & 0x2,
        equals(0x2),
        reason: 'link-down int',
      );
      await Simulator.endSimulation();
    });

    test('retrains through Recovery back to L0', () async {
      await setUpDut();
      await bw(_ctrl, 0x1);
      expect((await waitLinkUp()) & 0x1, equals(0x1));
      // Request a retrain. The LTSSM should visit Recovery (state 4) then L0.
      await bw(_linkCtrl, 0x1);
      var sawRecovery = false;
      var backToL0 = false;
      for (var i = 0; i < 40; i++) {
        final st = (await br(_status) >> 16) & 0x7;
        if (st == 4) sawRecovery = true;
        if (sawRecovery && st == 3) {
          backToL0 = true;
          break;
        }
      }
      expect(sawRecovery, isTrue, reason: 'entered Recovery');
      expect(backToL0, isTrue, reason: 'returned to L0');
      await Simulator.endSimulation();
    });

    test('link disable forces the link down', () async {
      await setUpDut();
      await bw(_ctrl, 0x1);
      expect((await waitLinkUp()) & 0x1, equals(0x1));
      await bw(_linkCtrl, 0x2); // link disable
      var down = false;
      for (var i = 0; i < 20; i++) {
        if ((await br(_status)) & 0x1 == 0) {
          down = true;
          break;
        }
      }
      expect(down, isTrue, reason: 'disabled link is down');
      // STATUS ltssm should read Detect (0).
      expect((await br(_status) >> 16) & 0x7, equals(0));
      await Simulator.endSimulation();
    });

    test('intEnable gates the interrupt output', () async {
      await setUpDut();
      await bw(_intEnable, 0x1); // enable link-up interrupt
      await bw(_ctrl, 0x1);
      await waitLinkUp();
      expect(pcie.interrupt.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });

    test('ECAM exposes the host-bridge Type 1 header at 00:00.0', () async {
      await setUpDut();
      expect(
        await er(ecamAddr(0, 0, 0, 0x00)),
        equals(0x00081B36),
        reason: 'vendor/device',
      );
      expect(
        await er(ecamAddr(0, 0, 0, 0x08)),
        equals(0x06040001),
        reason: 'class/rev (PCI bridge)',
      );
      expect(
        (await er(ecamAddr(0, 0, 0, 0x0C)) >> 16) & 0xFF,
        equals(0x01),
        reason: 'header type 1',
      );
      expect(
        await er(ecamAddr(0, 0, 0, 0x34)) & 0xFF,
        equals(0x40),
        reason: 'capability pointer',
      );
      expect(
        await er(ecamAddr(0, 0, 0, 0x40)) & 0xFF,
        equals(0x05),
        reason: 'MSI capability id',
      );
      await Simulator.endSimulation();
    });

    test('ECAM command and bus-number registers are writable', () async {
      await setUpDut();
      await ew(ecamAddr(0, 0, 0, 0x04), 0x0006); // mem + bus master enable
      expect(await er(ecamAddr(0, 0, 0, 0x04)) & 0xFFFF, equals(0x0006));
      // primary 0, secondary 1, subordinate 1
      await ew(ecamAddr(0, 0, 0, 0x18), 0x00010100);
      expect(await er(ecamAddr(0, 0, 0, 0x18)), equals(0x00010100));
      await Simulator.endSimulation();
    });

    test('ECAM master-aborts absent functions with all ones', () async {
      await setUpDut();
      expect(
        await er(ecamAddr(1, 0, 0, 0x00)),
        equals(0xFFFFFFFF),
        reason: 'no device on bus 1',
      );
      expect(
        await er(ecamAddr(0, 1, 0, 0x00)),
        equals(0xFFFFFFFF),
        reason: 'no device 1 on bus 0',
      );
      await Simulator.endSimulation();
    });

    test(
      'ECAM BAR writes are visible through the controller register',
      () async {
        await setUpDut();
        await ew(ecamAddr(0, 0, 0, 0x10), 0xC0000000); // BAR0 via config space
        expect(
          await br(0x40),
          equals(0xC0000000),
          reason: 'BAR0 shared with controller reg 0x040',
        );
        await Simulator.endSimulation();
      },
    );

    Future<void> waitTlpDone() async {
      for (var i = 0; i < 60; i++) {
        if ((await br(_tlpStatus)) & 0x2 == 0x2) return;
      }
    }

    test('TLP memory write moves the buffer into endpoint memory', () async {
      await setUpDut();
      await bw(_tlpAddrLo, 0x10); // word 4
      await bw(_tlpAddrHi, 0x0);
      await bw(_tlpLen, 3);
      await bw(_tlpData, 0x11111111);
      await bw(_tlpData, 0x22222222);
      await bw(_tlpData, 0x33333333);
      await bw(_tlpCtrl, 0x3); // start | write
      await waitTlpDone();
      expect(mem[4].value.toInt(), equals(0x11111111));
      expect(mem[5].value.toInt(), equals(0x22222222));
      expect(mem[6].value.toInt(), equals(0x33333333));
      // Header: MWr (fmt/type byte 0x40), length 3, address 0x10.
      final h0 = await br(_tlpHdr0);
      expect((h0 >> 24) & 0xFF, equals(0x40), reason: 'MWr fmt/type');
      expect(h0 & 0x3FF, equals(3), reason: 'length 3 DW');
      expect(await br(_tlpHdr2), equals(0x10), reason: 'address DW');
      await Simulator.endSimulation();
    });

    test('TLP memory read pulls endpoint memory into the buffer', () async {
      await setUpDut();
      await bw(_tlpAddrLo, 0x08); // word 2 (preset 0xAA02..)
      await bw(_tlpLen, 2);
      await bw(_tlpCtrl, 0x1); // start | read
      await waitTlpDone();
      expect(await br(_tlpData), equals(0xAA02));
      expect(await br(_tlpData), equals(0xAA03));
      final h0 = await br(_tlpHdr0);
      expect((h0 >> 24) & 0xFF, equals(0x00), reason: 'MRd fmt/type');
      await Simulator.endSimulation();
    });

    test('MSI trigger writes msi data to the msi address', () async {
      await setUpDut();
      await bw(_msiAddr, 0x20); // word 8
      await bw(_msiData, 0x00C5);
      await bw(_intEnable, 0x4); // enable MSI interrupt
      await bw(_msiTrigger, 0x3); // vector 3
      await waitTlpDone();
      expect(
        mem[8].value.toInt(),
        equals(0x00C5 | 0x3),
        reason: 'msi data | vector',
      );
      expect(
        (await br(_msiPend)) & (1 << 3),
        equals(1 << 3),
        reason: 'MSI pending bit 3',
      );
      expect((await br(_intStatus)) & 0x4, equals(0x4), reason: 'MSI int');
      expect(pcie.interrupt.value.toInt(), equals(1));
      await Simulator.endSimulation();
    });
  });

  group('HarborPcieController endpoint', () {
    late HarborPcieController pcie;
    late Logic clk, reset;
    late Logic estb, ewe, eadr, emosi;
    late Logic epValid, epWrite, epAddr, epWdata;
    late List<Logic> emem; // endpoint local memory model

    int ecamAddr(int bus, int dev, int fn, int regByte) =>
        (bus << 18) | (dev << 13) | (fn << 10) | (regByte >> 2);

    Future<int> er(int addr) async {
      eadr.inject(addr);
      ewe.inject(0);
      estb.inject(1);
      await clk.nextPosedge;
      while (pcie.output('ecam_ACK').value.toInt() != 1) {
        await clk.nextPosedge;
      }
      final v = pcie.output('ecam_DAT_MISO').value.toInt();
      estb.inject(0);
      await clk.nextPosedge;
      return v;
    }

    // Presents one inbound MWr/MRd request and returns the completion data.
    Future<int> epReq(int addr, {bool write = false, int wdata = 0}) async {
      epAddr.inject(addr);
      epWdata.inject(wdata);
      epWrite.inject(write ? 1 : 0);
      epValid.inject(1);
      await clk.nextPosedge;
      epValid.inject(0);
      for (var i = 0; i < 20; i++) {
        if (pcie.output('ep_req_ack').value.toInt() == 1) break;
        await clk.nextPosedge;
      }
      final cpl = pcie.output('ep_cpl_data').value.toInt();
      await clk.nextPosedge;
      return cpl;
    }

    Future<void> setUpDut() async {
      pcie = HarborPcieController(
        config: const HarborPcieConfig(role: HarborPcieRole.endpoint),
        baseAddress: 0xE000,
        ecamBase: 0x10000000,
      );
      clk = SimpleClockGenerator(10).clk;
      reset = Logic(name: 'reset');
      estb = Logic(name: 'estb');
      ewe = Logic(name: 'ewe');
      eadr = Logic(name: 'eadr', width: 26);
      emosi = Logic(name: 'emosi', width: 32);
      epValid = Logic(name: 'ep_valid');
      epWrite = Logic(name: 'ep_write');
      epAddr = Logic(name: 'ep_addr', width: 32);
      epWdata = Logic(name: 'ep_wdata', width: 32);

      pcie.input('clk').srcConnection! <= clk;
      pcie.input('reset').srcConnection! <= reset;
      pcie.input('wake_n').srcConnection! <= Const(1);
      for (var i = 0; i < 4; i++) {
        pcie.input('rxp_$i').srcConnection! <= Const(0);
        pcie.input('rxn_$i').srcConnection! <= Const(1);
      }
      // Controller register bus and outbound master port are unused here.
      pcie.input('bus_CYC').srcConnection! <= Const(0);
      pcie.input('bus_STB').srcConnection! <= Const(0);
      pcie.input('bus_WE').srcConnection! <= Const(0);
      pcie.input('bus_ADR').srcConnection! <= Const(0, width: 12);
      pcie.input('bus_DAT_MOSI').srcConnection! <= Const(0, width: 32);
      pcie.input('bus_SEL').srcConnection! <=
          Const(0xF, width: pcie.input('bus_SEL').width);
      pcie.input('pcie_m_rdata').srcConnection! <= Const(0, width: 32);
      pcie.input('pcie_m_ack').srcConnection! <= Const(0);
      // ECAM config-space port (host reads the EP's Type 0 header).
      pcie.input('ecam_CYC').srcConnection! <= estb;
      pcie.input('ecam_STB').srcConnection! <= estb;
      pcie.input('ecam_WE').srcConnection! <= ewe;
      pcie.input('ecam_ADR').srcConnection! <= eadr;
      pcie.input('ecam_DAT_MOSI').srcConnection! <= emosi;
      pcie.input('ecam_SEL').srcConnection! <=
          Const(0xF, width: pcie.input('ecam_SEL').width);
      // Inbound target request port.
      pcie.input('ep_req_valid').srcConnection! <= epValid;
      pcie.input('ep_req_write').srcConnection! <= epWrite;
      pcie.input('ep_req_addr').srcConnection! <= epAddr;
      pcie.input('ep_req_wdata').srcConnection! <= epWdata;

      // Endpoint local memory backing the ep_m_* port.
      emem = List.generate(16, (i) => Logic(name: 'emem_$i', width: 32));
      final emAddr = pcie.output('ep_m_addr');
      final emWdata = pcie.output('ep_m_wdata');
      final emWe = pcie.output('ep_m_we');
      final emStb = pcie.output('ep_m_stb');
      final wordIdx = emAddr.getRange(2, 6);
      Logic rd = Const(0, width: 32);
      for (var i = 15; i >= 0; i--) {
        rd = mux(wordIdx.eq(Const(i, width: 4)), emem[i], rd);
      }
      pcie.input('ep_m_rdata').srcConnection! <= rd;
      pcie.input('ep_m_ack').srcConnection! <= emStb;
      Sequential(clk, [
        If(
          reset,
          then: [
            for (var i = 0; i < 16; i++) emem[i] < Const(0xBB00 + i, width: 32),
          ],
          orElse: [
            If(
              emStb & emWe,
              then: [
                for (var i = 0; i < 16; i++)
                  If(wordIdx.eq(Const(i, width: 4)), then: [emem[i] < emWdata]),
              ],
            ),
          ],
        ),
      ]);

      await pcie.build();
      reset.inject(1);
      estb.inject(0);
      ewe.inject(0);
      eadr.inject(0);
      emosi.inject(0);
      epValid.inject(0);
      epWrite.inject(0);
      epAddr.inject(0);
      epWdata.inject(0);
      Simulator.setMaxSimTime(10000000);
      unawaited(Simulator.run());
      await clk.nextPosedge;
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;
    }

    test('exposes a Type 0 configuration header', () async {
      await setUpDut();
      expect(
        await er(ecamAddr(0, 0, 0, 0x00)),
        equals(0x10EF1AF4),
        reason: 'endpoint vendor/device',
      );
      expect(
        (await er(ecamAddr(0, 0, 0, 0x0C)) >> 16) & 0xFF,
        equals(0x00),
        reason: 'header type 0 (endpoint)',
      );
      await Simulator.endSimulation();
    });

    test('inbound memory write lands in endpoint memory', () async {
      await setUpDut();
      await epReq(0x10, write: true, wdata: 0xCAFEF00D); // word 4
      expect(emem[4].value.toInt(), equals(0xCAFEF00D));
      await Simulator.endSimulation();
    });

    test('inbound memory read returns a completion', () async {
      await setUpDut();
      // Memory preset to 0xBB00 + index. Word 2 holds 0xBB02.
      expect(await epReq(0x08), equals(0xBB02));
      // After a write, a read returns the new value.
      await epReq(0x14, write: true, wdata: 0x12345678); // word 5
      expect(await epReq(0x14), equals(0x12345678));
      await Simulator.endSimulation();
    });
  });
}
