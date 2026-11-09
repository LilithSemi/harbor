import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// AV1 Decoded Picture Buffer (DPB): the 8-slot reference frame store, its
/// refresh (`refresh_frame_flags`) bookkeeping, and per-block reference
/// selection (`ref_frame_idx` remap). A decoded frame is written into the DPB,
/// later frames pull it back out as a motion-compensation reference, as the CDF
/// carry-in for `primary_ref_frame`, and as the temporal-MV (TMVP) source.
///
/// Two layers, mirroring how real silicon splits this:
///
///  * [HarborDpbControl] (a ROHD hardware module) is the control plane: eight
///    registered slots, each holding an `order_hint`, a `valid` bit, and a small
///    opaque `handle` that indexes the bulk payload store. Refresh,
///    `show_existing_frame` (copy one slot into the refreshed slots), and
///    reference selection (`ref_frame_idx[ref - LAST]` -> slot) live here. This
///    is tiny register + mux logic.
///
///  * [HarborDpb] / [HarborRefFrame] (Dart) is the data plane: the bulk payload
///    each `handle` points at, i.e. the reconstructed Y/U/V planes, the per-8x8
///    saved MVs (+ ref frame) for TMVP, the adapted CDF state for the
///    `primary_ref_frame` carry-in, the segment map, global motion, and the
///    saved order hints. In hardware these are large external-memory surfaces
///    (a frame buffer + side-band RAMs), so the model keeps them as a
///    handle-indexed memory rather than flops. The control plane never moves
///    pixels. It only decides which handle a reference reads.
///
/// Reference frame numbering follows the AV1 spec: INTRA_FRAME = 0,
/// LAST_FRAME = 1 ... ALTREF_FRAME = 7.

/// INTRA_FRAME.
const dpbRefIntra = 0;

/// LAST_FRAME (the first inter reference).
const dpbRefLast = 1;

/// ALTREF_FRAME (the last inter reference).
const dpbRefAltref = 7;

/// Number of reference slots in the DPB (NUM_REF_FRAMES).
const dpbNumRefFrames = 8;

/// Number of references usable by one inter frame (REFS_PER_FRAME).
const dpbRefsPerFrame = 7;

/// `primary_ref_frame` sentinel meaning "no primary reference" (PRIMARY_REF_NONE).
const dpbPrimaryRefNone = 7;

/// One stored reference frame: the data-plane payload a DPB slot's `handle`
/// points at. These are the fields a later inter frame reads back out of the
/// buffer.
class HarborRefFrame {
  /// Reconstructed (pre-film-grain) planes. The reference is always the
  /// pre-grain reconstruction, grain is applied only to the displayed copy.
  List<List<int>> planeY;
  List<List<int>> planeU;
  List<List<int>> planeV;

  /// This frame's order hint.
  final int orderHint;

  /// `OrderHints[LAST..ALTREF]` saved with this frame (for order-hint distance
  /// of a later frame that references it).
  final List<int> savedOrderHints;

  final int width;
  final int height;
  final int miCols;
  final int miRows;
  final int frameType;
  final bool showableFrame;

  /// Per-8x8 saved reference frame of each block (for temporal MV projection).
  final List<List<int>>? mvRefFrame;

  /// Per-8x8 saved MVs `[mi8row][mi8col] -> [mvRow, mvCol]` (for TMVP).
  final List<List<List<int>>>? mvs;

  /// Saved per-ref global-motion warp params `[ref][6]`.
  final List<List<int>> globalMotion;

  /// Saved adaptive CDF context (end-of-frame) for `primary_ref_frame`
  /// carry-in. A fixed-order list of `[count, ...icdf]` per CDF context.
  final List<List<int>>? cdfState;

  /// Saved per-mi segment_id map (for temporal segmentation prediction).
  final List<List<int>>? segMap;

  /// Saved segmentation feature params (inherited when `update_data == 0`).
  final List<List<bool>>? segFeatureEnabled;
  final List<List<int>>? segFeatureData;

  HarborRefFrame({
    required this.planeY,
    required this.planeU,
    required this.planeV,
    required this.orderHint,
    List<int>? savedOrderHints,
    this.width = 0,
    this.height = 0,
    this.miCols = 0,
    this.miRows = 0,
    this.frameType = 0,
    this.showableFrame = false,
    this.mvRefFrame,
    this.mvs,
    List<List<int>>? globalMotion,
    this.cdfState,
    this.segMap,
    this.segFeatureEnabled,
    this.segFeatureData,
  }) : savedOrderHints =
           savedOrderHints ?? List<int>.filled(dpbRefsPerFrame, 0),
       globalMotion =
           globalMotion ??
           List.generate(dpbNumRefFrames, (_) => [0, 0, 0, 0, 0, 0]);
}

/// The Dart data-plane model of the DPB: the 8-slot handle store plus the bulk
/// payloads, with the payload lookups (planes / CDF carry-in / TMVP MVs) the
/// multi-frame orchestrator drives.
///
/// `updateRefs` applies `refresh_frame_flags`. `showExistingFrame` handles the
/// `show_existing_frame` path. `selectRef` is the per-block
/// `refFrameMap[refFrameIdx[ref - LAST]]` selection. `primaryRef` is the
/// `refFrameMap[refFrameIdx[primary_ref_frame]]` CDF/seg carry-in.
class HarborDpb {
  /// The 8 reference slots (null = invalid / never written).
  final List<HarborRefFrame?> slots = List<HarborRefFrame?>.filled(
    dpbNumRefFrames,
    null,
  );

  /// Whether slot `i` holds a decoded frame.
  bool valid(int slot) => slots[slot] != null;

  /// The order hint stored in slot `i` (0 if invalid).
  int orderHint(int slot) => slots[slot]?.orderHint ?? 0;

  /// Write [frame] into every slot `i` selected by `refresh_frame_flags`
  /// (`(refreshFrameFlags >> i) & 1`).
  void updateRefs(int refreshFrameFlags, HarborRefFrame frame) {
    for (var i = 0; i < dpbNumRefFrames; i++) {
      if ((refreshFrameFlags >> i) & 1 != 0) {
        slots[i] = frame;
      }
    }
  }

  /// `show_existing_frame`: pull the frame in slot [frameToShowMapIdx] and,
  /// when it is a shown keyframe (or otherwise refreshes), copy it into every
  /// slot selected by [refreshFrameFlags]. Returns the shown frame (or null).
  HarborRefFrame? showExistingFrame(
    int frameToShowMapIdx, {
    int refreshFrameFlags = 0,
  }) {
    final shown = slots[frameToShowMapIdx];
    if (shown == null) return null;
    for (var i = 0; i < dpbNumRefFrames; i++) {
      if ((refreshFrameFlags >> i) & 1 != 0) {
        slots[i] = shown;
      }
    }
    return shown;
  }

  /// The slot a given reference [ref] (LAST..ALTREF) maps to for a frame with
  /// this [refFrameIdx] remap: `refFrameIdx[ref - LAST]`.
  int slotForRef(List<int> refFrameIdx, int ref) =>
      refFrameIdx[ref - dpbRefLast];

  /// Per-block reference selection: the stored frame [ref] (LAST..ALTREF)
  /// points at, i.e. `refFrameMap[refFrameIdx[ref - LAST]]`.
  HarborRefFrame? selectRef(List<int> refFrameIdx, int ref) =>
      slots[slotForRef(refFrameIdx, ref)];

  /// The `primary_ref_frame` carry-in source: the frame whose adapted CDFs /
  /// segmentation the current frame inherits, i.e.
  /// `refFrameMap[refFrameIdx[primary_ref_frame]]` (null when there is no
  /// primary reference).
  HarborRefFrame? primaryRef(List<int> refFrameIdx, int primaryRefFrame) {
    if (primaryRefFrame == dpbPrimaryRefNone) return null;
    return slots[refFrameIdx[primaryRefFrame]];
  }

  /// The CDF state carried in for [primaryRefFrame] (null -> use defaults).
  List<List<int>>? primaryRefCdf(List<int> refFrameIdx, int primaryRefFrame) =>
      primaryRef(refFrameIdx, primaryRefFrame)?.cdfState;
}

/// The DPB control plane in hardware: eight registered reference slots plus
/// refresh / show-existing bookkeeping and combinational reference selection.
///
/// Each slot holds an `order_hint`, a `valid` bit, and a `handle` (an opaque
/// index into the bulk [HarborRefFrame] payload store). One decoded frame is
/// applied per `refresh` (or `show_existing`) pulse. The selection ports remap
/// a reference number through `ref_frame_idx` to the physical slot the way
/// `set_frame_refs` prescribes, so a consumer reads the right frame's handle /
/// order hint without touching pixels.
///
/// Ports:
///  * inputs:
///     - `clk`, `reset`
///     - `refresh_en` (1): pulse to apply `refresh_frame_flags` this cycle
///     - `refresh_flags` ([dpbNumRefFrames]): `refresh_frame_flags`
///     - `order_hint_in` ([orderHintWidth]): order hint of the frame stored
///     - `handle_in` ([handleWidth]): payload handle of the frame stored
///     - `show_en` (1): pulse to apply a `show_existing_frame` refresh
///     - `show_idx` (3): the slot being shown (`frame_to_show_map_idx`)
///     - `ref_frame_idx` (7 x 3 = 21b, LAST..ALTREF packed LSB-first): the
///       `ref_frame_idx` remap of the current frame
///     - `sel_ref` (4): the reference to select, LAST..ALTREF (1..7), 0 = none
///  * outputs:
///     - `slot_valid` ([dpbNumRefFrames]): per-slot valid bits
///     - `slot_order_hints` (8 x [orderHintWidth] packed): per-slot order hints
///     - `slot_handles` (8 x [handleWidth] packed): per-slot handles
///     - `sel_slot` (3): `ref_frame_idx[sel_ref - LAST]`
///     - `sel_valid` (1), `sel_order_hint` ([orderHintWidth]),
///       `sel_handle` ([handleWidth]): the selected slot's registered state
class HarborDpbControl extends BridgeModule {
  /// Bit width of each stored order hint (AV1 order hints fit in 8 bits).
  final int orderHintWidth;

  /// Bit width of each payload handle (indexes the [HarborRefFrame] store).
  final int handleWidth;

  HarborDpbControl({
    this.orderHintWidth = 8,
    this.handleWidth = 4,
    String? name,
  }) : super('HarborDpbControl', name: name ?? 'dpb_control') {
    if (orderHintWidth < 1) {
      throw ArgumentError(
        'HarborDpbControl.orderHintWidth must be >= 1, got $orderHintWidth',
      );
    }
    if (handleWidth < 1) {
      throw ArgumentError(
        'HarborDpbControl.handleWidth must be >= 1, got $handleWidth',
      );
    }

    createPort('clk', PortDirection.input, width: 1);
    createPort('reset', PortDirection.input, width: 1);
    createPort('refresh_en', PortDirection.input, width: 1);
    createPort('refresh_flags', PortDirection.input, width: dpbNumRefFrames);
    createPort('order_hint_in', PortDirection.input, width: orderHintWidth);
    createPort('handle_in', PortDirection.input, width: handleWidth);
    createPort('show_en', PortDirection.input, width: 1);
    createPort('show_idx', PortDirection.input, width: 3);
    createPort(
      'ref_frame_idx',
      PortDirection.input,
      width: dpbRefsPerFrame * 3,
    );
    createPort('sel_ref', PortDirection.input, width: 4);

    addOutput('slot_valid', width: dpbNumRefFrames);
    addOutput('slot_order_hints', width: dpbNumRefFrames * orderHintWidth);
    addOutput('slot_handles', width: dpbNumRefFrames * handleWidth);
    addOutput('sel_slot', width: 3);
    addOutput('sel_valid', width: 1);
    addOutput('sel_order_hint', width: orderHintWidth);
    addOutput('sel_handle', width: handleWidth);

    final clk = input('clk');
    final reset = input('reset');
    final refreshEn = input('refresh_en');
    final refreshFlags = input('refresh_flags');
    final orderHintIn = input('order_hint_in');
    final handleIn = input('handle_in');
    final showEn = input('show_en');
    final showIdx = input('show_idx');
    final refFrameIdx = input('ref_frame_idx');
    final selRef = input('sel_ref');

    // Registered slot state.
    final slotValid = List.generate(
      dpbNumRefFrames,
      (i) => Logic(name: 'slot_valid_$i'),
    );
    final slotOh = List.generate(
      dpbNumRefFrames,
      (i) => Logic(name: 'slot_oh_$i', width: orderHintWidth),
    );
    final slotHandle = List.generate(
      dpbNumRefFrames,
      (i) => Logic(name: 'slot_handle_$i', width: handleWidth),
    );

    // Read a slot's registered state by a 3-bit index (mux tree over the 8
    // slots). Used by `show_existing` (read the shown slot) and by selection.
    Logic slotOhAt(Logic idx) => idx.selectFrom(slotOh);
    Logic slotHandleAt(Logic idx) => idx.selectFrom(slotHandle);
    Logic slotValidAt(Logic idx) => idx.selectFrom(slotValid);

    final showOh = slotOhAt(showIdx);
    final showHandle = slotHandleAt(showIdx);

    // Per-slot refresh: `show_existing` copies the shown slot, a normal refresh
    // writes the incoming frame, otherwise the slot holds.
    Sequential(clk, reset: reset, [
      for (var i = 0; i < dpbNumRefFrames; i++)
        If(
          showEn & refreshFlags[i],
          then: [
            slotValid[i] < Const(1),
            slotOh[i] < showOh,
            slotHandle[i] < showHandle,
          ],
          orElse: [
            If(
              refreshEn & refreshFlags[i],
              then: [
                slotValid[i] < Const(1),
                slotOh[i] < orderHintIn,
                slotHandle[i] < handleIn,
              ],
            ),
          ],
        ),
    ]);

    output('slot_valid') <= slotValid.rconcat();
    output('slot_order_hints') <= slotOh.rconcat();
    output('slot_handles') <= slotHandle.rconcat();

    // Reference selection: slot = ref_frame_idx[sel_ref - LAST]. sel_ref is
    // LAST..ALTREF (1..7), the remap entry is 3 bits at (sel_ref - 1) * 3.
    final refM1 = (selRef - Const(dpbRefLast, width: 4)).getRange(0, 4);
    final remapEntries = [
      for (var i = 0; i < dpbRefsPerFrame; i++)
        refFrameIdx.getRange(i * 3, i * 3 + 3),
    ];
    final selSlot = refM1.selectFrom(remapEntries);
    output('sel_slot') <= selSlot;
    output('sel_valid') <= slotValidAt(selSlot);
    output('sel_order_hint') <= slotOhAt(selSlot);
    output('sel_handle') <= slotHandleAt(selSlot);
  }
}
