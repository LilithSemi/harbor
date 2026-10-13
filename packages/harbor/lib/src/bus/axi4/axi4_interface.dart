import 'package:rohd/rohd.dart';

/// A full AXI4 interface using [PairInterface], without REGION and USER.
///
/// Provider role is the manager. Consumer role is the subordinate. The port
/// names match the AXI4 signal names and the rohd_hcl AXI4 interfaces.
class Axi4Interface extends PairInterface {
  /// Address width in bits.
  final int addressWidth;

  /// Data width in bits.
  final int dataWidth;

  /// Width of AWID, ARID, BID and RID.
  final int idWidth;

  static const int lenWidth = 8;
  static const int sizeWidth = 3;
  static const int burstWidth = 2;
  static const int cacheWidth = 4;
  static const int protWidth = 3;
  static const int qosWidth = 4;
  static const int respWidth = 2;

  Logic get awId => port('AWID');
  Logic get awAddr => port('AWADDR');
  Logic get awLen => port('AWLEN');
  Logic get awSize => port('AWSIZE');
  Logic get awBurst => port('AWBURST');
  Logic get awLock => port('AWLOCK');
  Logic get awCache => port('AWCACHE');
  Logic get awProt => port('AWPROT');
  Logic get awQos => port('AWQOS');
  Logic get awValid => port('AWVALID');
  Logic get awReady => port('AWREADY');

  Logic get wData => port('WDATA');
  Logic get wStrb => port('WSTRB');
  Logic get wLast => port('WLAST');
  Logic get wValid => port('WVALID');
  Logic get wReady => port('WREADY');

  Logic get bId => port('BID');
  Logic get bResp => port('BRESP');
  Logic get bValid => port('BVALID');
  Logic get bReady => port('BREADY');

  Logic get arId => port('ARID');
  Logic get arAddr => port('ARADDR');
  Logic get arLen => port('ARLEN');
  Logic get arSize => port('ARSIZE');
  Logic get arBurst => port('ARBURST');
  Logic get arLock => port('ARLOCK');
  Logic get arCache => port('ARCACHE');
  Logic get arProt => port('ARPROT');
  Logic get arQos => port('ARQOS');
  Logic get arValid => port('ARVALID');
  Logic get arReady => port('ARREADY');

  Logic get rId => port('RID');
  Logic get rData => port('RDATA');
  Logic get rResp => port('RRESP');
  Logic get rLast => port('RLAST');
  Logic get rValid => port('RVALID');
  Logic get rReady => port('RREADY');

  Axi4Interface({
    required this.addressWidth,
    required this.dataWidth,
    required this.idWidth,
  }) : super(
         portsFromProvider: [
           for (final p in ['AW', 'AR']) ...[
             Logic.port('${p}ID', idWidth),
             Logic.port('${p}ADDR', addressWidth),
             Logic.port('${p}LEN', lenWidth),
             Logic.port('${p}SIZE', sizeWidth),
             Logic.port('${p}BURST', burstWidth),
             Logic.port('${p}LOCK'),
             Logic.port('${p}CACHE', cacheWidth),
             Logic.port('${p}PROT', protWidth),
             Logic.port('${p}QOS', qosWidth),
             Logic.port('${p}VALID'),
           ],
           Logic.port('WDATA', dataWidth),
           Logic.port('WSTRB', dataWidth ~/ 8),
           Logic.port('WLAST'),
           Logic.port('WVALID'),
           Logic.port('BREADY'),
           Logic.port('RREADY'),
         ],
         portsFromConsumer: [
           Logic.port('AWREADY'),
           Logic.port('WREADY'),
           Logic.port('BID', idWidth),
           Logic.port('BRESP', respWidth),
           Logic.port('BVALID'),
           Logic.port('ARREADY'),
           Logic.port('RID', idWidth),
           Logic.port('RDATA', dataWidth),
           Logic.port('RRESP', respWidth),
           Logic.port('RLAST'),
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
    if (idWidth < 1) {
      throw ArgumentError.value(idWidth, 'idWidth', 'must be >= 1');
    }
  }

  @override
  Axi4Interface clone() => Axi4Interface(
    addressWidth: addressWidth,
    dataWidth: dataWidth,
    idWidth: idWidth,
  );
}
