import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import 'test_harness.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Audio Controller sim', () {
    test('write VOLUME_L and read back', () async {
      final audio = HarborAudioController(baseAddress: 0x10060000);

      audio.port('sdata_in').getsLogic(Const(0));
      _tieOff(audio);

      final tb = PeripheralTestBench(audio);
      await tb.init();

      // VOLUME_L at byte offset 0x80
      await tb.write(0x80, 200);
      final volL = await tb.read(0x80);
      expect(volL & 0xFF, equals(200));

      await Simulator.endSimulation();
    });

    test('write VOLUME_R and read back', () async {
      final audio = HarborAudioController(baseAddress: 0x10060000);

      audio.port('sdata_in').getsLogic(Const(0));
      _tieOff(audio);

      final tb = PeripheralTestBench(audio);
      await tb.init();

      // VOLUME_R at byte offset 0x88
      await tb.write(0x88, 128);
      final volR = await tb.read(0x88);
      expect(volR & 0xFF, equals(128));

      await Simulator.endSimulation();
    });

    test('write MUTE register', () async {
      final audio = HarborAudioController(baseAddress: 0x10060000);

      audio.port('sdata_in').getsLogic(Const(0));
      _tieOff(audio);

      final tb = PeripheralTestBench(audio);
      await tb.init();

      // MUTE at byte offset 0x90
      await tb.write(0x90, 0x03);
      final mute = await tb.read(0x90);
      expect(mute & 0x03, equals(0x03));

      await Simulator.endSimulation();
    });

    test('write CTRL enable and read back', () async {
      final audio = HarborAudioController(baseAddress: 0x10060000);

      audio.port('sdata_in').getsLogic(Const(0));
      _tieOff(audio);

      final tb = PeripheralTestBench(audio);
      await tb.init();

      // CTRL at byte offset 0x00
      await tb.write(0x00, 0x01);
      final ctrl = await tb.read(0x00);
      expect(ctrl & 0x01, equals(0x01));

      await Simulator.endSimulation();
    });

    test('write INT_ENABLE and read back', () async {
      final audio = HarborAudioController(baseAddress: 0x10060000);

      audio.port('sdata_in').getsLogic(Const(0));
      _tieOff(audio);

      final tb = PeripheralTestBench(audio);
      await tb.init();

      // INT_ENABLE at byte offset 0x78
      await tb.write(0x78, 0xFF);
      final intEn = await tb.read(0x78);
      expect(intEn & 0xFF, equals(0xFF));

      await Simulator.endSimulation();
    });
  });
}

/// Ties the stream ready and the DMA master port inputs to 0.
void _tieOff(HarborAudioController audio) {
  audio.port('audio_ready').getsLogic(Const(0));
  for (final p in audio.inputs.keys.where((p) => p.startsWith('dma_'))) {
    audio.port(p).getsLogic(Const(0, width: audio.input(p).width));
  }
}
