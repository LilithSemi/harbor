import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

const _target = HarborFpgaTarget.ecp5(device: 'LFE5U-85F', package: 'CABGA381');

HarborSdram _sdram({HarborScanoutLine? line, int clockHz = 25000000}) =>
    HarborSdram(
      config: const HarborSdramConfig.as4c16m16sb6(),
      baseAddress: 0x80000000,
      clockHz: clockHz,
      busClockSync: true,
      scanoutPorts: 1,
      scanoutLine: line,
      target: _target,
    );

void main() {
  const line = HarborScanoutLine(words: 640, periodCycles: 800, syncCycles: 7);

  test('the worst line fetch at 25 MHz fits a 640x480 rgb565 line', () {
    final s = _sdram(line: line);
    final bound = HarborSdram.scanoutLineBound(
      s.cycles,
      s.config,
      640,
      periodCycles: 800,
    );
    expect(bound, 764);
    expect(
      HarborSdram.scanoutLineFits(s.cycles, s.config, 640, 800, syncCycles: 7),
      isTrue,
    );
    expect(s.busWaitBound, greaterThan(bound));
  });

  test('a line period shorter than the bound is rejected', () {
    expect(
      () => _sdram(
        line: const HarborScanoutLine(
          words: 640,
          periodCycles: 700,
          syncCycles: 7,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('a line of xrgb8888 at 25 MHz is rejected', () {
    expect(
      () => _sdram(
        line: const HarborScanoutLine(
          words: 1280,
          periodCycles: 800,
          syncCycles: 7,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('a guard needs a scanout port', () {
    expect(
      () => HarborSdram(
        config: const HarborSdramConfig.as4c16m16sb6(),
        baseAddress: 0x80000000,
        clockHz: 25000000,
        busClockSync: true,
        scanoutLine: line,
        target: _target,
      ),
      throwsArgumentError,
    );
  });

  test('the guard changes the definition name', () {
    expect(_sdram(line: line).definitionName, isNot(_sdram().definitionName));
  });

  test('a line period in cycles follows the clocks', () {
    final l = HarborScanoutLine.forMode(
      timing: const HarborDisplayTiming.vga640x480(),
      formats: const [HarborPixelFormat.rgb565, HarborPixelFormat.xrgb8888],
      pixelClockHz: 25000000,
      sdramClockHz: 100000000,
    );
    expect(l.words, 1280);
    expect(l.periodCycles, 3200);
  });
}
