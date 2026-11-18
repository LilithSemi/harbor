import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async => Simulator.reset());

  HarborGtpPciePhy gtp(int lanes) => HarborGtpPciePhy(
    perstN: Logic(),
    common: HarborGtpCommonPorts(),
    channels: [for (var i = 0; i < lanes; i++) HarborGtpChannelPorts()],
    pipes: [for (var i = 0; i < lanes; i++) HarborPciePipeLane()],
    lanes: lanes,
    timeouts: const HarborGtpPcieTimeouts(linkWait: 0),
  );

  test('GTP x1 has a 62.5 MHz user clock, x4 has 125 MHz', () {
    expect(gtp(1).userClkHz, 62500000);
    expect(gtp(4).userClkHz, 125000000);
  });

  test('the Artix-7 PHY top reports the x1 user clock', () {
    final phy = HarborArtix7PciePhy(
      refClkP: Logic(),
      refClkN: Logic(),
      perstN: Logic(),
      rxP: Logic(),
      rxN: Logic(),
      pipe: HarborPciePipeLane(),
      timeouts: const HarborGtpPcieTimeouts(linkWait: 0),
    );
    expect(phy.userClkHz, 62500000);
  });

  for (final (gen2, hz) in [(false, 62500000), (true, 125000000)]) {
    test('GTX gen2 $gen2 has a $hz Hz user clock', () {
      final phy = HarborGtxPciePhy(
        perstN: Logic(),
        channel: HarborGtxChannelPorts(),
        pipe: HarborPciePipeLane(),
        gen2: gen2,
        timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
      );
      expect(phy.userClkHz, hz);
      final top = HarborKintex7PciePhy(
        refClkP: Logic(),
        refClkN: Logic(),
        perstN: Logic(),
        rxP: Logic(),
        rxN: Logic(),
        pipe: HarborPciePipeLane(),
        gen2: gen2,
        timeouts: const HarborGtxPcieTimeouts(linkWait: 0),
      );
      expect(top.userClkHz, hz);
    });
  }
}
