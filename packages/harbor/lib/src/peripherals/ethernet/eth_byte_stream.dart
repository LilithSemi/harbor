import 'package:rohd/rohd.dart';

/// Byte stream between the MAC core and a PHY front end.
///
/// The front end is the provider. It drives the clocks, the resets and the
/// receive side. The MAC is the consumer and drives the transmit side. A
/// strobe high means the byte on that side is valid in this cycle. It stays
/// high at 1000 Mbps and pulses at the byte rate at lower speeds.
class HarborEthByteStream extends PairInterface {
  /// Transmit clock.
  Logic get txClk => port('tx_clk');

  /// Transmit reset, active high.
  Logic get txReset => port('tx_reset');

  /// Receive clock.
  Logic get rxClk => port('rx_clk');

  /// Receive reset, active high.
  Logic get rxReset => port('rx_reset');

  /// Transmit data byte.
  Logic get txData => port('tx_data');

  /// Transmit enable.
  Logic get txEn => port('tx_en');

  /// Transmit error.
  Logic get txEr => port('tx_er');

  /// Transmit byte slot. High when the byte on [txData] is taken.
  Logic get txStrobe => port('tx_strobe');

  /// Receive data byte.
  Logic get rxData => port('rx_data');

  /// Receive data valid.
  Logic get rxDv => port('rx_dv');

  /// Receive error.
  Logic get rxEr => port('rx_er');

  /// Receive byte slot. High when the byte on [rxData] is valid.
  Logic get rxStrobe => port('rx_strobe');

  HarborEthByteStream()
    : super(
        portsFromProvider: [
          Logic.port('tx_clk'),
          Logic.port('tx_reset'),
          Logic.port('rx_clk'),
          Logic.port('rx_reset'),
          Logic.port('tx_strobe'),
          Logic.port('rx_data', 8),
          Logic.port('rx_dv'),
          Logic.port('rx_er'),
          Logic.port('rx_strobe'),
        ],
        portsFromConsumer: [
          Logic.port('tx_data', 8),
          Logic.port('tx_en'),
          Logic.port('tx_er'),
        ],
      );

  @override
  HarborEthByteStream clone() => HarborEthByteStream();
}
