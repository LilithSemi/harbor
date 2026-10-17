import '../../util/pretty_string.dart';

/// Ethernet PHY interface a MAC is built for.
enum HarborEthPhy {
  /// Media independent interface.
  mii,

  /// Reduced media independent interface.
  rmii,

  /// Reduced gigabit media independent interface.
  rgmii,
}

/// Ethernet link speed.
enum HarborEthSpeed {
  /// 10 Mbps.
  mbps10(10),

  /// 100 Mbps.
  mbps100(100),

  /// 1000 Mbps.
  mbps1000(1000);

  /// Speed in Mbps.
  final int mbps;

  const HarborEthSpeed(this.mbps);
}

/// Ethernet MAC configuration. Each option that is off builds no logic.
class HarborEthernetConfig with HarborPrettyString {
  /// PHY interface.
  final HarborEthPhy phy;

  /// Highest link speed.
  final HarborEthSpeed maxSpeed;

  /// Multicast hash filter.
  final bool multicastHash;

  /// Promiscuous mode.
  final bool promiscuous;

  /// Pause frames. Not built yet, so it must be false.
  final bool pause;

  /// Checksum offload. Not built yet, so it must be false.
  final bool checksumOffload;

  /// PTP timestamping. Descriptors grow to 32 bytes. Not built yet, so it
  /// must be false.
  final bool ptp;

  /// MDIO clause 45 access.
  final bool mdioC45;

  /// TX FIFO size in bytes.
  final int txFifoBytes;

  /// RX FIFO size in bytes.
  final int rxFifoBytes;

  /// Outstanding bus transactions.
  final int outstanding;

  /// Beats in one DMA burst.
  final int burstBeats;

  /// RGMII only. When true, the MAC sends the TX clock 90 degrees after the
  /// data. When false, the clock and the data have the same phase and the PHY
  /// must add the clock delay.
  final bool txClockShift;

  /// RGMII only. Input delay taps on the RX data and control. 0 builds no
  /// delay line.
  final int rgmiiRxDelayTaps;

  /// RGMII only. True when the PHY adds the RX clock delay, so the RX data
  /// arrives centered on the clock. It selects the input delay constraints.
  final bool rgmiiPhyRxDelay;

  /// MDIO address of the PHY on the board, 0 to 31, or null when it is not
  /// known. With an address the device tree has a PHY node and a
  /// `phy-handle`. It builds no logic.
  final int? phyAddress;

  /// Extra device tree properties of the PHY node, such as the KSZ9031
  /// `rxc-skew-ps`. Used only with [phyAddress].
  final Map<String, Object> phyDtProperties;

  /// RGMII only. Time in ns that the RX data is valid before each RX clock
  /// edge at the pins, or null for the value from [rgmiiPhyRxDelay]. Give it
  /// with [rgmiiRxHoldNs]. It sets the input delay constraints.
  final double? rgmiiRxSetupNs;

  /// RGMII only. Time in ns that the RX data stays valid after each RX clock
  /// edge at the pins, or null. See [rgmiiRxSetupNs].
  final double? rgmiiRxHoldNs;

  /// Creates a configuration and checks it.
  ///
  /// Throws [ArgumentError] when [pause], [checksumOffload] or [ptp] is
  /// true, when gigabit is used without RGMII, when a FIFO size is not a
  /// power of two of at least 2048, when [burstBeats] is not in 1 to 256,
  /// when [outstanding] is less than 1, when [rgmiiRxDelayTaps] is less
  /// than 0, when [phyAddress] is not in 0 to 31, or when only one of
  /// [rgmiiRxSetupNs] and [rgmiiRxHoldNs] is given.
  HarborEthernetConfig({
    required this.phy,
    this.maxSpeed = HarborEthSpeed.mbps100,
    this.multicastHash = false,
    this.promiscuous = false,
    this.pause = false,
    this.checksumOffload = false,
    this.ptp = false,
    this.mdioC45 = false,
    this.txFifoBytes = 2048,
    this.rxFifoBytes = 2048,
    this.outstanding = 1,
    this.burstBeats = 4,
    this.txClockShift = true,
    this.rgmiiRxDelayTaps = 0,
    this.rgmiiPhyRxDelay = true,
    this.phyAddress,
    this.phyDtProperties = const {},
    this.rgmiiRxSetupNs,
    this.rgmiiRxHoldNs,
  }) {
    for (final (on, name) in [
      (pause, 'pause'),
      (checksumOffload, 'checksumOffload'),
      (ptp, 'ptp'),
    ]) {
      if (on) {
        throw ArgumentError.value(on, name, 'is not built yet, set it false');
      }
    }
    if ((rgmiiRxSetupNs == null) != (rgmiiRxHoldNs == null)) {
      throw ArgumentError('give rgmiiRxSetupNs and rgmiiRxHoldNs together');
    }
    if (phyAddress != null && (phyAddress! < 0 || phyAddress! > 31)) {
      throw ArgumentError.value(phyAddress, 'phyAddress', 'must be 0 to 31');
    }
    if (maxSpeed == HarborEthSpeed.mbps1000 && phy != HarborEthPhy.rgmii) {
      throw ArgumentError('1000 Mbps needs the rgmii phy');
    }
    _checkFifo('txFifoBytes', txFifoBytes);
    _checkFifo('rxFifoBytes', rxFifoBytes);
    if (burstBeats < 1 || burstBeats > 256) {
      throw ArgumentError.value(burstBeats, 'burstBeats', 'must be 1 to 256');
    }
    if (rgmiiRxDelayTaps < 0) {
      throw ArgumentError.value(
        rgmiiRxDelayTaps,
        'rgmiiRxDelayTaps',
        'must be 0 or more',
      );
    }
    if (outstanding < 1) {
      throw ArgumentError.value(
        outstanding,
        'outstanding',
        'must be 1 or more',
      );
    }
  }

  /// Smallest MAC: 100 Mbps, unicast and broadcast filter only.
  factory HarborEthernetConfig.basic({required HarborEthPhy phy}) =>
      HarborEthernetConfig(phy: phy);

  /// Full MAC. Pause, checksum offload and PTP stay off until they exist.
  factory HarborEthernetConfig.full({required HarborEthPhy phy}) =>
      HarborEthernetConfig(
        phy: phy,
        maxSpeed: phy == HarborEthPhy.rgmii
            ? HarborEthSpeed.mbps1000
            : HarborEthSpeed.mbps100,
        multicastHash: true,
        promiscuous: true,
        txFifoBytes: 4096,
        rxFifoBytes: 4096,
        outstanding: 4,
        burstBeats: 16,
      );

  /// MAC for one KSZ9031 RGMII PHY of the Alinx AX7203, with the options
  /// of [HarborEthernetConfig.full].
  ///
  /// The KSZ9031 has no delay strap. It adds 1.2 ns to RX_CLK and no delay
  /// to TX_CLK by default (Microchip DS00002117F), so the MAC shifts the TX
  /// clock. The device tree mode is `rgmii-rxid` with `rxc-skew-ps = 240`:
  /// the RX_CLK pad skew is -0.66 ns (DS00002117F Table 3-5), so the clock
  /// is about 0.54 ns after the data. With no RX delay taps, that puts the
  /// data window on the BUFIO clocked IDDRs of an XC7A200T-2 (DS181 Table
  /// 47) with about 0.4 ns on each side. The data is valid from 0.04 ns
  /// before to 1.86 ns after each RX clock edge (Table 7-1, TsetupT/TholdT
  /// and TskewT). Both PHYs have the MDIO address 1 from their straps.
  factory HarborEthernetConfig.ax7203() => HarborEthernetConfig(
    phy: HarborEthPhy.rgmii,
    maxSpeed: HarborEthSpeed.mbps1000,
    multicastHash: true,
    promiscuous: true,
    txFifoBytes: 4096,
    rxFifoBytes: 4096,
    outstanding: 4,
    burstBeats: 16,
    txClockShift: true,
    rgmiiRxDelayTaps: 0,
    rgmiiPhyRxDelay: true,
    phyAddress: 1,
    phyDtProperties: const {'rxc-skew-ps': 240},
    rgmiiRxSetupNs: 0.04,
    rgmiiRxHoldNs: 1.86,
  );

  static void _checkFifo(String name, int bytes) {
    if (bytes < 2048 || (bytes & (bytes - 1)) != 0) {
      throw ArgumentError.value(
        bytes,
        name,
        'must be a power of two of at least 2048',
      );
    }
  }

  /// Descriptor size in bytes.
  int get descBytes => ptp ? 32 : 16;

  /// Value of the HW_CAPS register. Bits 6 to 8 (pause, checksum offload
  /// and PTP) read 0, since these blocks are not built.
  int get hwCaps {
    int log2(int v) => v.bitLength - 1;
    return (phy == HarborEthPhy.mii ? 1 : 0) |
        (phy == HarborEthPhy.rmii ? 1 << 1 : 0) |
        (phy == HarborEthPhy.rgmii ? 1 << 2 : 0) |
        (maxSpeed == HarborEthSpeed.mbps1000 ? 1 << 3 : 0) |
        (multicastHash ? 1 << 4 : 0) |
        (promiscuous ? 1 << 5 : 0) |
        (mdioC45 ? 1 << 9 : 0) |
        (log2(descBytes) << 12) |
        (log2(txFifoBytes) << 16) |
        (log2(rxFifoBytes) << 24);
  }

  @override
  String toString() =>
      'HarborEthernetConfig(${maxSpeed.mbps} Mbps, ${phy.name})';

  @override
  String toPrettyString([
    HarborPrettyStringOptions options = const HarborPrettyStringOptions(),
  ]) {
    final p = options.prefix;
    final c = options.childPrefix;
    final buf = StringBuffer('${p}HarborEthernetConfig(\n');
    buf.writeln('${c}phy: ${phy.name}, speed: ${maxSpeed.mbps} Mbps,');
    buf.writeln('${c}txFifo: $txFifoBytes, rxFifo: $rxFifoBytes,');
    buf.writeln('${c}outstanding: $outstanding, burst: $burstBeats,');
    final on = [
      if (multicastHash) 'multicastHash',
      if (promiscuous) 'promiscuous',
      if (mdioC45) 'mdioC45',
    ];
    buf.writeln('${c}options: ${on.join(', ')},');
    buf.write('$p)');
    return buf.toString();
  }
}
