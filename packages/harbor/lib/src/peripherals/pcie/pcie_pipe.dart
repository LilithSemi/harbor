import 'package:rohd/rohd.dart';

/// PIPE signals between one PCIe PHY lane and a controller hard block.
class HarborPciePipeLane extends PairInterface {
  Logic get txData => port('txdata');
  Logic get txDataK => port('txdatak');
  Logic get txDetectRx => port('txdetectrx');
  Logic get txElecIdle => port('txelecidle');
  Logic get txCompliance => port('txcompliance');
  Logic get rxPolarity => port('rxpolarity');
  Logic get powerDown => port('powerdown');
  Logic get pipeRate => port('rate');
  Logic get txMargin => port('txmargin');
  Logic get txSwing => port('txswing');
  Logic get txDeemph => port('txdeemph');
  Logic get rxData => port('rxdata');
  Logic get rxDataK => port('rxdatak');
  Logic get rxValid => port('rxvalid');
  Logic get phyStatus => port('phystatus');
  Logic get rxElecIdle => port('rxelecidle');
  Logic get rxStatus => port('rxstatus');
  Logic get rxChanIsAligned => port('rxchanisaligned');

  HarborPciePipeLane()
    : super(
        portsFromProvider: [
          Logic.port('rxdata', 16),
          Logic.port('rxdatak', 2),
          Logic.port('rxvalid'),
          Logic.port('phystatus'),
          Logic.port('rxelecidle'),
          Logic.port('rxstatus', 3),
          Logic.port('rxchanisaligned'),
        ],
        portsFromConsumer: [
          Logic.port('txdata', 16),
          Logic.port('txdatak', 2),
          Logic.port('txdetectrx'),
          Logic.port('txelecidle'),
          Logic.port('txcompliance'),
          Logic.port('rxpolarity'),
          Logic.port('powerdown', 2),
          Logic.port('rate'),
          Logic.port('txmargin', 3),
          Logic.port('txswing'),
          Logic.port('txdeemph'),
        ],
      );

  @override
  HarborPciePipeLane clone() => HarborPciePipeLane();
}
