import 'io_ring.dart';

/// A fab die slot with a fixed pad opening at each pad position.
///
/// Values are in um with the origin at the lower left corner of the full
/// slot. Each center is the center of a pad opening along its side: x for
/// south and north, y for east and west.
class HarborFabSlot {
  final String name;

  /// Full slot width, seal ring included.
  final double widthUm;

  /// Full slot height, seal ring included.
  final double heightUm;

  /// Distance from the slot edge to the outer edge of each pad opening.
  final double openingInsetUm;

  /// Pad opening centers on each side, in increasing order.
  final Map<HarborIoPadEdge, List<double>> centers;

  HarborFabSlot({
    required this.name,
    required this.widthUm,
    required this.heightUm,
    required this.openingInsetUm,
    required Map<HarborIoPadEdge, List<double>> centers,
  }) : centers = Map.unmodifiable({
         for (final e in HarborIoPadEdge.values)
           e: List<double>.unmodifiable(
             centers[e] ??
                 (throw ArgumentError('Slot $name has no ${e.name} pads')),
           ),
       }) {
    for (final MapEntry(key: e, value: list) in this.centers.entries) {
      for (var i = 1; i < list.length; i++) {
        if (list[i] <= list[i - 1]) {
          throw ArgumentError(
            'Slot $name has ${e.name} pad centers out of order at $i',
          );
        }
      }
    }
  }

  /// Number of pad positions on side [e].
  int positions(HarborIoPadEdge e) => centers[e]!.length;

  /// A slot whose south and north pads, and east and west pads, are at
  /// even steps.
  factory HarborFabSlot.evenPitch({
    required String name,
    required double widthUm,
    required double heightUm,
    required double openingInsetUm,
    required (double, double, int) horizontal,
    required (double, double, int) vertical,
  }) {
    List<double> row((double, double, int) r) => [
      for (var k = 0; k < r.$3; k++) r.$1 + r.$2 * k,
    ];
    return HarborFabSlot(
      name: name,
      widthUm: widthUm,
      heightUm: heightUm,
      openingInsetUm: openingInsetUm,
      centers: {
        HarborIoPadEdge.south: row(horizontal),
        HarborIoPadEdge.north: row(horizontal),
        HarborIoPadEdge.east: row(vertical),
        HarborIoPadEdge.west: row(vertical),
      },
    );
  }

  /// wafer.space gf180mcu slots, from the golden pad masks of
  /// wafer-space/gf180mcu-precheck rev 9b4e7da (layer 37/0).
  static final Map<String, HarborFabSlot> waferSpace = {
    for (final s in [
      HarborFabSlot.evenPitch(
        name: '0p5x0p5',
        widthUm: 1936,
        heightUm: 2531,
        openingInsetUm: 28,
        horizontal: (448, 104, 11),
        vertical: (449.5, 102, 17),
      ),
      HarborFabSlot.evenPitch(
        name: '0p5x1',
        widthUm: 1936,
        heightUm: 5122,
        openingInsetUm: 28,
        horizontal: (485, 138, 8),
        vertical: (509, 152, 28),
      ),
      HarborFabSlot.evenPitch(
        name: '1x0p5',
        widthUm: 3932,
        heightUm: 2531,
        openingInsetUm: 28,
        horizontal: (482.5, 129, 24),
        vertical: (490, 141, 12),
      ),
      HarborFabSlot.evenPitch(
        name: '1x1',
        widthUm: 3932,
        heightUm: 5122,
        openingInsetUm: 28,
        horizontal: (526, 180, 17),
        vertical: (556.5, 211, 20),
      ),
    ])
      s.name: s,
  };

  @override
  String toString() => 'HarborFabSlot($name)';
}
