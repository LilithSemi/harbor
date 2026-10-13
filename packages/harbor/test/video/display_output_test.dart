import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// The output-type selector accepts every HarborDisplayInterface value (so
/// genip can offer all of them) but only validates the ones with a built
/// backend. DVI and HDMI ride the TMDS transmitter, parallelRgb forwards the
/// pixel clock instead. VGA and DisplayPort are accepted in the type system
/// but rejected with a clear error for now.
void main() {
  group('display output support', () {
    test('dvi and hdmi are supported', () {
      expect(isDisplayOutputSupported(HarborDisplayInterface.dvi), isTrue);
      expect(isDisplayOutputSupported(HarborDisplayInterface.hdmi), isTrue);
    });

    test('parallelRgb is supported', () {
      expect(
        isDisplayOutputSupported(HarborDisplayInterface.parallelRgb),
        isTrue,
      );
    });

    test('vga, displayPort, and friends are not supported yet', () {
      expect(isDisplayOutputSupported(HarborDisplayInterface.vga), isFalse);
      expect(
        isDisplayOutputSupported(HarborDisplayInterface.displayPort),
        isFalse,
      );
    });

    test('require throws for unsupported and passes for supported', () {
      expect(
        () => requireDisplayOutputSupported(HarborDisplayInterface.displayPort),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => requireDisplayOutputSupported(HarborDisplayInterface.hdmi),
        returnsNormally,
      );
    });
  });

  test('HarborFramebufferDisplay rejects an unsupported output type', () {
    Logic l([int w = 1]) => Logic(width: w);
    expect(
      () => HarborFramebufferDisplay(
        target: const HarborSimTarget(),
        timing: const HarborDisplayTiming.vga640x480(),
        pixelClk: l(),
        pixelReset: l(),
        shiftClk: l(),
        shiftReset: l(),
        enable: l(),
        fbBase: l(32),
        mDataIn: l(32),
        mAck: l(),
        outputType: HarborDisplayInterface.displayPort,
      ),
      throwsA(isA<UnsupportedError>()),
    );
  });

  test(
    'a dvi/hdmi build keeps its definitionName and gpdi, no parallelRgb ports',
    () async {
      Logic l([int w = 1]) => Logic(width: w);
      final dvi = HarborFramebufferDisplay(
        target: const HarborSimTarget(),
        timing: const HarborDisplayTiming.vga640x480(),
        pixelClk: l(),
        pixelReset: l(),
        shiftClk: l(),
        shiftReset: l(),
        enable: l(),
        fbBase: l(32),
        mDataIn: l(32),
        mAck: l(),
        // hdmi is the default; this is explicit only to document it.
        outputType: HarborDisplayInterface.hdmi,
      );
      await dvi.build();
      expect(dvi.definitionName, equals('HarborFramebufferDisplay'));
      final sv = dvi.generateSynth();
      expect(sv, contains('gpdi'));
      expect(sv, isNot(contains('rgb')));
      expect(sv, isNot(contains('pclk')));
      expect(sv, isNot(contains('ParallelRgb')));
    },
  );

  test('a parallelRgb build gets its own definitionName and rgb/pclk ports, '
      'no gpdi', () async {
    Logic l([int w = 1]) => Logic(width: w);
    final prgb = HarborFramebufferDisplay(
      target: const HarborSimTarget(),
      timing: const HarborDisplayTiming.vga640x480(),
      pixelClk: l(),
      pixelReset: l(),
      shiftClk: l(),
      shiftReset: l(),
      enable: l(),
      fbBase: l(32),
      mDataIn: l(32),
      mAck: l(),
      outputType: HarborDisplayInterface.parallelRgb,
    );
    await prgb.build();
    expect(prgb.definitionName, equals('HarborFramebufferDisplay_parallelRgb'));
    final sv = prgb.generateSynth();
    expect(sv, contains('rgb'));
    expect(sv, contains('pclk'));
    expect(sv, isNot(contains('gpdi')));
    expect(sv, isNot(contains('DviTransmitter')));
    expect(sv, isNot(contains('TmdsEncoder')));
    expect(sv, isNot(contains('TmdsSerializer')));
  });
}
