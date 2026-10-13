import 'package:rohd/rohd.dart';

/// An AXI4-Lite interface using [PairInterface].
///
/// Provider role is the manager. Consumer role is the subordinate. The port
/// names match the AXI4 signal names, so a full AXI4 interface can connect to
/// it by name.
class Axi4LiteInterface extends PairInterface {
  /// Address width in bits.
  final int addressWidth;

  /// Data width in bits.
  final int dataWidth;

  /// Width of AWPROT and ARPROT.
  static const int protWidth = 3;

  /// Width of BRESP and RRESP.
  static const int respWidth = 2;

  Logic get awAddr => port('AWADDR');
  Logic get awProt => port('AWPROT');
  Logic get awValid => port('AWVALID');
  Logic get awReady => port('AWREADY');

  Logic get wData => port('WDATA');
  Logic get wStrb => port('WSTRB');
  Logic get wValid => port('WVALID');
  Logic get wReady => port('WREADY');

  Logic get bResp => port('BRESP');
  Logic get bValid => port('BVALID');
  Logic get bReady => port('BREADY');

  Logic get arAddr => port('ARADDR');
  Logic get arProt => port('ARPROT');
  Logic get arValid => port('ARVALID');
  Logic get arReady => port('ARREADY');

  Logic get rData => port('RDATA');
  Logic get rResp => port('RRESP');
  Logic get rValid => port('RVALID');
  Logic get rReady => port('RREADY');

  Axi4LiteInterface({required this.addressWidth, required this.dataWidth})
    : super(
        portsFromProvider: [
          Logic.port('AWADDR', addressWidth),
          Logic.port('AWPROT', protWidth),
          Logic.port('AWVALID'),
          Logic.port('WDATA', dataWidth),
          Logic.port('WSTRB', dataWidth ~/ 8),
          Logic.port('WVALID'),
          Logic.port('BREADY'),
          Logic.port('ARADDR', addressWidth),
          Logic.port('ARPROT', protWidth),
          Logic.port('ARVALID'),
          Logic.port('RREADY'),
        ],
        portsFromConsumer: [
          Logic.port('AWREADY'),
          Logic.port('WREADY'),
          Logic.port('BRESP', respWidth),
          Logic.port('BVALID'),
          Logic.port('ARREADY'),
          Logic.port('RDATA', dataWidth),
          Logic.port('RRESP', respWidth),
          Logic.port('RVALID'),
        ],
      ) {
    if (addressWidth < 1 || addressWidth > 64) {
      throw ArgumentError.value(addressWidth, 'addressWidth', 'must be 1..64');
    }
    if (dataWidth < 8 || dataWidth > 1024 || dataWidth & (dataWidth - 1) != 0) {
      throw ArgumentError.value(
        dataWidth,
        'dataWidth',
        'must be a power of two from 8 to 1024',
      );
    }
  }

  @override
  Axi4LiteInterface clone() =>
      Axi4LiteInterface(addressWidth: addressWidth, dataWidth: dataWidth);
}
