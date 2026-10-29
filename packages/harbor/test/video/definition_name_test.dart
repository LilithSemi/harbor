import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

HarborDoubleLineBuffer _buffer(
  int maxWords,
  HarborBlockRam? blockRam, {
  int colWidth = 2,
}) => HarborDoubleLineBuffer(
  wrClk: Logic(),
  wrEn: Logic(),
  wrSel: Logic(),
  wrIdx: Logic(width: (maxWords - 1).bitLength),
  wrData: Logic(width: 32),
  rdClk: Logic(),
  rdReset: Logic(),
  rdSel: Logic(),
  rdCol: Logic(width: colWidth),
  maxWords: maxWords,
  blockRam: blockRam,
);

TmdsSerializer _serializer(HarborDeviceTarget target) => TmdsSerializer(
  shiftClk: Logic(),
  reset: Logic(),
  symbol: Logic(width: 10),
  align: Logic(),
  target: target,
);

DviTransmitter _dvi(HarborDeviceTarget target, {bool hdmi = false}) =>
    DviTransmitter(
      target: target,
      pixelClk: Logic(),
      shiftClk: Logic(),
      pixelReset: Logic(),
      shiftReset: Logic(),
      de: Logic(),
      hsync: Logic(),
      vsync: Logic(),
      red: Logic(width: 8),
      green: Logic(width: 8),
      blue: Logic(width: 8),
      hdmiMode: hdmi ? Logic(width: 6) : null,
      hdmiAux: hdmi ? Logic(width: 12) : null,
      hdmiCtl: hdmi ? Logic(width: 4) : null,
    );

const _ecp5 = HarborFpgaTarget.ecp5(device: '25k', package: 'CABGA381');
const _xilinx = HarborFpgaTarget(
  name: 'arty',
  vendor: HarborFpgaVendor.openXc7,
  device: 'xc7a35t',
  package: 'csg324',
);

void main() {
  tearDown(() async => Simulator.reset());

  test('line buffer name follows the parameters', () {
    final base = _buffer(64, null).definitionName;
    expect(_buffer(64, null).definitionName, base);
    expect(_buffer(128, null).definitionName, isNot(base));
    expect(_buffer(64, HarborBlockRam.dp16kd).definitionName, isNot(base));
    expect(
      _buffer(64, HarborBlockRam.dp16kd).definitionName,
      isNot(_buffer(64, HarborBlockRam.ramb).definitionName),
    );
    expect(_buffer(64, null, colWidth: 6).definitionName, isNot(base));
  });

  test('serializer name follows the target kind', () {
    final sim = _serializer(const HarborSimTarget()).definitionName;
    expect(_serializer(const HarborSimTarget()).definitionName, sim);
    expect(_serializer(_ecp5).definitionName, isNot(sim));
    expect(_serializer(_xilinx).definitionName, isNot(sim));
    expect(
      _serializer(_xilinx).definitionName,
      isNot(_serializer(_ecp5).definitionName),
    );
  });

  test('transmitter name follows the target kind and the HDMI mode', () {
    final sim = _dvi(const HarborSimTarget()).definitionName;
    expect(_dvi(const HarborSimTarget()).definitionName, sim);
    expect(
      _dvi(const HarborSimTarget(), hdmi: true).definitionName,
      isNot(sim),
    );
    expect(_dvi(_ecp5).definitionName, isNot(sim));
    expect(_dvi(_xilinx).definitionName, isNot(_dvi(_ecp5).definitionName));
    expect(
      _dvi(_ecp5, hdmi: true).definitionName,
      isNot(_dvi(_ecp5).definitionName),
    );
  });
}
