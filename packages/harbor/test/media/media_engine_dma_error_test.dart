// A bus error on a DMA access stops the media engine session.

import 'dart:async';

import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

const _engCtrl = 0x00;
const _engStatus = 0x08;
const _intStatus = 0x20;
const _intEnable = 0x28;
const _s0Ctrl = 0x100;
const _s0Status = 0x108;
const _s0Src = 0x110;
const _s0Dst = 0x120;

void main() {
  tearDown(() async => Simulator.reset());

  for (final onWrite in [false, true]) {
    test(
      'a ${onWrite ? 'write' : 'read'} bus error stops the session',
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
        final errOn = Logic(name: 'err_on');
        eng.input('clk').srcConnection! <= clk;
        eng.input('reset').srcConnection! <= reset;
        eng.input('bus_CYC').srcConnection! <= stb;
        eng.input('bus_STB').srcConnection! <= stb;
        eng.input('bus_WE').srcConnection! <= we;
        eng.input('bus_ADR').srcConnection! <= adr;
        eng.input('bus_DAT_MOSI').srcConnection! <= mosi;
        eng.input('bus_SEL').srcConnection! <=
            Const(0xF, width: eng.input('bus_SEL').width);
        final rreq = eng.output('dma_read_req');
        final wreq = eng.output('dma_write_req');
        eng.input('dma_read_data').srcConnection! <= Const(0, width: 128);
        eng.input('dma_read_valid').srcConnection! <= rreq;
        eng.input('dma_write_ack').srcConnection! <= wreq;
        eng.input('dma_err').srcConnection! <= errOn & (onWrite ? wreq : rreq);
        var writes = 0;
        await eng.build();
        reset.inject(1);
        stb.inject(0);
        we.inject(0);
        adr.inject(0);
        mosi.inject(0);
        errOn.inject(1);
        clk.posedge.listen((_) {
          if (wreq.value.isValid && wreq.value.toBool()) writes++;
        });
        Simulator.setMaxSimTime(10000000);
        unawaited(Simulator.run());
        await clk.nextPosedge;
        await clk.nextPosedge;
        reset.inject(0);
        await clk.nextPosedge;

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

        await bw(_engCtrl, 1);
        await bw(_intEnable, 1);
        expect(eng.output('interrupt').value.toInt(), 0);
        await bw(_s0Src, 0);
        await bw(_s0Dst, 0x80);
        await bw(_s0Ctrl, 1);
        for (var i = 0; i < 400 && (await br(_intStatus)) & 1 == 0; i++) {}
        expect(await br(_intStatus) & 1, 1, reason: 'session interrupt bit');
        expect(eng.output('interrupt').value.toInt(), 1, reason: 'pin');
        expect(await br(_s0Status), 4, reason: 'error status, not done');
        expect(await br(_engStatus) & 1, 1);
        if (!onWrite)
          expect(writes, 0, reason: 'a failed read starts no write');

        await bw(_engStatus, 0xFFFFFFFE);
        expect(await br(_engStatus) & 1, 1, reason: 'only bit 0 clears it');
        await bw(_engStatus, 1);
        expect(await br(_engStatus), 0, reason: 'W1C');
        await Simulator.endSimulation();
      },
    );
  }
}
