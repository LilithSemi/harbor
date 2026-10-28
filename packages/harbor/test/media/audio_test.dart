import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  group('HarborAudioFormat', () {
    test('bits per sample', () {
      expect(HarborAudioFormat.s16le.bitsPerSample, equals(16));
      expect(HarborAudioFormat.s24le.bitsPerSample, equals(24));
      expect(HarborAudioFormat.s32le.bitsPerSample, equals(32));
      expect(HarborAudioFormat.float32.bitsPerSample, equals(32));
    });
  });

  group('HarborAudioInterface', () {
    test('all interfaces defined', () {
      expect(HarborAudioInterface.values, hasLength(5));
    });
  });

  group('HarborAudioController', () {
    test('creates with defaults', () {
      final audio = HarborAudioController(baseAddress: 0x10010000);
      expect(audio.maxChannels, equals(2));
      expect(audio.interrupt.width, equals(1));
      expect(audio.mclk.width, equals(1));
      expect(audio.bclk.width, equals(1));
      expect(audio.lrclk.width, equals(1));
      expect(audio.sdataOut.width, equals(1));
    });

    test('I2S interface signals', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        audioInterfaces: [HarborAudioInterface.i2s],
      );
      expect(audio.spdifOut, isNull);
      expect(audio.pdmClk, isNull);
    });

    test('S/PDIF interface', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        audioInterfaces: [HarborAudioInterface.i2s, HarborAudioInterface.spdif],
      );
      expect(audio.hasSpdif, isTrue);
      expect(audio.spdifOut, isNotNull);
      expect(audio.spdifIn, isNotNull);
    });

    test('PDM microphone interface', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        audioInterfaces: [HarborAudioInterface.i2s, HarborAudioInterface.pdm],
      );
      expect(audio.hasPdm, isTrue);
      expect(audio.pdmClk, isNotNull);
      expect(audio.pdmData, isNotNull);
    });

    test('hardware codec support', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        hwCodecs: [HarborAudioCodecFormat.aac, HarborAudioCodecFormat.opus],
      );
      expect(audio.hasHwCodec, isTrue);
      expect(audio.hwCodecs, hasLength(2));
    });

    test('no hardware codec', () {
      final audio = HarborAudioController(baseAddress: 0x10010000);
      expect(audio.hasHwCodec, isFalse);
    });

    test('multi-channel TDM', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        audioInterfaces: [HarborAudioInterface.tdm],
        maxChannels: 8,
      );
      expect(audio.maxChannels, equals(8));
    });

    test('sample rates', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        sampleRates: [44100, 48000, 96000, 192000],
      );
      expect(audio.maxSampleRate, equals(192000));
      expect(audio.sampleRates, hasLength(4));
    });

    test('DT node', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        maxChannels: 2,
        audioInterfaces: [HarborAudioInterface.i2s, HarborAudioInterface.spdif],
      );
      final dt = audio.dtNode;
      expect(dt.compatible.first, equals('harbor,audio'));
      expect(dt.reg.start, equals(0x10010000));
      expect(dt.properties['#sound-dai-cells'], equals(0));
      expect(dt.properties['harbor,max-channels'], equals(2));
      final interfaces = dt.properties['harbor,interfaces'] as String;
      expect(interfaces, contains('i2s'));
      expect(interfaces, contains('spdif'));
    });

    test('DMA master port and stream ports', () {
      final audio = HarborAudioController(baseAddress: 0x10010000);
      expect(audio.dma.waist.config.dataWidth, equals(32));
      expect(audio.dma.waist.config.addressWidth, equals(32));
      expect(audio.interfaces.keys, containsAll(['bus', 'dma']));
      expect(audio.audioLeft.width, equals(24));
      expect(audio.audioRight.width, equals(24));
      expect(audio.audioValid.width, equals(1));
      expect(audio.audioReady.width, equals(1));
      expect(audio.txUnderrunCount.width, equals(16));
      expect(audio.dmaError.width, equals(1));
      expect(audio.dmaTimeout.width, equals(1));
      expect(audio.dmaPtrError.width, equals(1));
      expect(audio.formats, equals([HarborAudioFormat.s24le]));
    });

    test('a DMA address wider than the 32-bit ring is rejected', () {
      expect(
        () =>
            HarborAudioController(baseAddress: 0x10010000, dmaAddressWidth: 40),
        throwsArgumentError,
      );
      expect(
        () =>
            HarborAudioController(baseAddress: 0x10010000, dmaAddressWidth: 32),
        returnsNormally,
      );
    });

    test('with sample rate converter', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        hasSrc: true,
      );
      expect(audio.hasSrc, isTrue);
      final dt = audio.dtNode;
      expect(dt.properties['harbor,has-src'], equals(true));
    });

    test('FIFO depths', () {
      final audio = HarborAudioController(
        baseAddress: 0x10010000,
        txFifoDepth: 16,
        rxFifoDepth: 512,
      );
      expect(audio.txFifoDepth, equals(16));
      expect(audio.rxFifoDepth, equals(512));
    });

    test('two parameter sets give different definitionNames', () {
      final a = HarborAudioController(baseAddress: 0x10010000);
      final b = HarborAudioController(
        baseAddress: 0x10010000,
        audioInterfaces: const [HarborAudioInterface.i2s],
        hwCodecs: const [HarborAudioCodecFormat.aac],
      );
      expect(a.definitionName, isNot(equals(b.definitionName)));
      final c = HarborAudioController(baseAddress: 0x10010000, txFifoDepth: 4);
      final d = HarborAudioController(
        baseAddress: 0x10010000,
        dmaTimeoutCycles: 100,
      );
      final names = {a, c, d}.map((m) => m.definitionName).toSet();
      expect(names, hasLength(3));
    });
  });

  group('HarborAudioCodecFormat', () {
    test('display names', () {
      expect(HarborAudioCodecFormat.aac.displayName, equals('AAC-LC'));
      expect(HarborAudioCodecFormat.opus.displayName, equals('Opus'));
      expect(HarborAudioCodecFormat.flac.displayName, equals('FLAC'));
    });

    test('all formats defined', () {
      expect(HarborAudioCodecFormat.values, hasLength(6));
    });
  });
}
