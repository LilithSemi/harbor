import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

HarborLedEngine _engine(
  List<HarborLedChannelConfig> channels, {
  int? clockHz,
  int maxPixels = 4,
  HarborLedPixelSource source = HarborLedPixelSource.ram,
}) => HarborLedEngine(
  baseAddress: 0x10005000,
  channels: channels,
  pixelSource: source,
  maxPixels: maxPixels,
  clockHz: clockHz,
);

void main() {
  test('a serial channel lists every pixel as RGB at full brightness', () {
    final dt = _engine(const [
      HarborLedChannelConfig.serial(),
    ], clockHz: 50000000).dtNode;
    expect(dt.properties['harbor,pixel-colors'], equals([0, 0, 0, 0]));
    expect(
      dt.properties['harbor,pixel-max-brightness'],
      equals([255, 255, 255, 255]),
    );
    expect(dt.properties['clock-frequency'], equals(50000000));
  });

  test('the arty-s7-50 preset lists 4 mono and 2 RGB pixels', () {
    final ch = HarborBoard.get('arty-s7-50').ledChannels.single.config;
    final led = _engine([ch], clockHz: 100000000, maxPixels: 8);
    for (final props in [led.dtNode.properties, led.acpiDevice.properties]) {
      expect(props['harbor,pixel-colors'], equals([1, 1, 1, 1, 0, 0]));
      expect(
        props['harbor,pixel-max-brightness'],
        equals([255, 255, 255, 255, 128, 128]),
      );
      expect(props['clock-frequency'], equals(100000000));
    }
  });

  test('a build without a pixel source has no pixel lists', () {
    final dt = _engine(const [
      HarborLedChannelConfig.serial(),
    ], source: HarborLedPixelSource.none).dtNode;
    expect(dt.properties.containsKey('harbor,pixel-colors'), isFalse);
  });

  test('a pixel takes the lowest max duty of its pins', () {
    final dt = _engine(const [
      HarborLedChannelConfig.pwm([
        HarborLedPin(0, HarborLedByte.r, maxDuty: 200),
        HarborLedPin(0, HarborLedByte.g, maxDuty: 100),
        HarborLedPin(0, HarborLedByte.b),
      ]),
    ]).dtNode;
    expect(dt.properties['harbor,pixel-colors'], equals([0]));
    expect(dt.properties['harbor,pixel-max-brightness'], equals([100]));
  });

  test('a pixel with one pin is mono and names its byte', () {
    final dt = _engine(const [
      HarborLedChannelConfig.pwm([
        HarborLedPin(0, HarborLedByte.r),
        HarborLedPin(1, HarborLedByte.b),
        HarborLedPin(2, HarborLedByte.r),
        HarborLedPin(2, HarborLedByte.g),
      ]),
    ]).dtNode;
    expect(dt.properties['harbor,pixel-colors'], equals([1, 1, 0]));
    expect(dt.properties['harbor,pixel-mono-byte'], equals([0, 2, 2]));
  });

  test(
    'the owner property appears only when a coprocessor owns the engine',
    () {
      final kernel = _engine(const [HarborLedChannelConfig.serial()]);
      expect(kernel.dtNode.properties.containsKey('harbor,owner'), isFalse);
      final cp = HarborLedEngine(baseAddress: 0x10005000, kernelOwned: false);
      expect(cp.dtNode.properties['harbor,owner'], equals('coprocessor'));
      expect(cp.acpiDevice.properties['harbor,owner'], equals('coprocessor'));
    },
  );

  test('a dma build gives the dma address width', () {
    final led = HarborLedEngine(
      baseAddress: 0x10005000,
      pixelSource: HarborLedPixelSource.dma,
      dmaAddressWidth: 40,
    );
    expect(led.dtNode.properties['harbor,dma-address-width'], equals(40));
    expect(
      _engine(const [
        HarborLedChannelConfig.serial(),
      ]).dtNode.properties.containsKey('harbor,dma-address-width'),
      isFalse,
    );
  });
}
