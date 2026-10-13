/// The bus fabric a SoC is built on. The port layer builds every device port
/// natively for this kind.
enum HarborFabricKind {
  /// Wishbone B4. Register ports are classic cycles.
  wishbone(ordersReadAfterWrite: true),

  /// AXI4. Register ports are AXI4-Lite, memory ports are full AXI4.
  axi4(ordersReadAfterWrite: false),

  /// TileLink. Register ports are TL-UL, memory ports are TL-UH.
  tilelink(ordersReadAfterWrite: false);

  /// Whether a read sent after a write by the same master always sees that
  /// write, even before the write response comes back. When false, a master
  /// that needs this order must hold the read until the write response.
  final bool ordersReadAfterWrite;

  const HarborFabricKind({required this.ordersReadAfterWrite});
}
