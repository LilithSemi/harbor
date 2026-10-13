import 'package:rohd/rohd.dart';

/// The register waist: one access at a time between a requester and a
/// register device, independent of the fabric kind.
///
/// The requester raises STB with ADDR, WE, WDATA and SEL and holds them until
/// the device raises ACK for one cycle. RDATA and ERR are valid in that cycle.
/// ADDR is a byte address aligned down to the data word, and SEL marks the
/// byte lanes of the access.
///
/// Provider role is the requester (a register master waist). Consumer role is
/// the device (a register slave waist).
class HarborRegisterWaist extends PairInterface {
  /// Address width in bits.
  final int addressWidth;

  /// Data width in bits.
  final int dataWidth;

  Logic get addr => port('ADDR');
  Logic get wdata => port('WDATA');
  Logic get stb => port('STB');
  Logic get we => port('WE');
  Logic get sel => port('SEL');
  Logic get rdata => port('RDATA');
  Logic get ack => port('ACK');
  Logic get err => port('ERR');

  HarborRegisterWaist({required this.addressWidth, required this.dataWidth})
    : super(
        portsFromProvider: [
          Logic.port('ADDR', addressWidth),
          Logic.port('WDATA', dataWidth),
          Logic.port('STB'),
          Logic.port('WE'),
          Logic.port('SEL', dataWidth ~/ 8),
        ],
        portsFromConsumer: [
          Logic.port('RDATA', dataWidth),
          Logic.port('ACK'),
          Logic.port('ERR'),
        ],
      ) {
    if (addressWidth < 1) {
      throw ArgumentError.value(addressWidth, 'addressWidth', 'must be >= 1');
    }
    if (dataWidth < 8 || dataWidth & (dataWidth - 1) != 0) {
      throw ArgumentError.value(
        dataWidth,
        'dataWidth',
        'must be a power of two >= 8',
      );
    }
  }

  @override
  HarborRegisterWaist clone() =>
      HarborRegisterWaist(addressWidth: addressWidth, dataWidth: dataWidth);
}

/// [addr] with the byte offset inside a [dataWidth]-bit word cleared.
Logic harborWordAddress(Logic addr, int dataWidth) {
  final lowBits = (dataWidth ~/ 8).bitLength - 1;
  if (lowBits == 0) return addr;
  if (lowBits >= addr.width) return Const(0, width: addr.width);
  return [addr.getRange(lowBits), Const(0, width: lowBits)].swizzle();
}
