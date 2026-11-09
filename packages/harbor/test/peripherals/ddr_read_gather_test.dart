import 'package:test/test.dart';

/// Gather-order guard for the DLL-on trainable ECP5 DQS read (issue: the
/// 144MHz DLL-on read was BEAT-SCRAMBLED: a written 5A5A5A5A read back as
/// A5975210 at every tap). Root cause: the old bitslip was a same-cycle 4-way
/// rotation of the current sclk cycle's four Q sub-beats, which can only permute
/// WITHIN one cycle and can never realign a burst whose beat0 fell in the
/// previous cycle. The fix (litedram ecp5ddrphy.py L376-400) replaces it with a
/// single BitSlip that slides a window across the {prev4, cur4} 8-beat history,
/// i.e. an 8-position rotation: aligned[p] = hist8[(slp + p) % 8].
///
/// This test rebuilds EXACTLY that rotation permutation in isolation (the
/// IDDRX2DQA Q outputs are SystemVerilog-leaf X in sim, so the full PHY read
/// cannot be co-simulated, but the fabric rotation is plain combinational logic
/// and IS sim-visible). It locks in the gather order: for every bitslip 0..7 and
/// every requested word 0..3, the two beats that land in the fabric word are the
/// correct pair from the rotated 8-beat burst, and the packing half-order
/// (packWord = [evenBeat, oddBeat].concat, the HW-verified within-word order)
/// is preserved.
void main() {
  // Mirror of the PHY's alignedBeat()/packWord(): the same 8-position rotation
  // and half-pack the RTL uses, computed in Dart so the test is the golden model.
  int alignedBeat(List<int> hist8, int slp, int p) => hist8[(slp + p) % 8];
  // packWord(evenBeat, oddBeat) = [oddBeat, evenBeat].concat() -> the ODD beat in
  // the MSBs (HALF-SWAP FIX 2026-07-11). The WRITE path packs the EVEN beat = rise =
  // low16 and the ODD beat = fall = high16, so to round-trip a written word EXACTLY
  // the read must put the odd beat (high16) in the MSBs: readWord = (odd<<16)|even.
  // (The prior model put evenBeat in the MSBs AND modeled beat0 = high16 below: two
  // inverted assumptions that cancelled, hiding the real-silicon half-swap.)
  int packWord(int evenBeat, int oddBeat) =>
      ((oddBeat & 0xFFFF) << 16) | (evenBeat & 0xFFFF);
  int selWord(List<int> hist8, int slp, int wordSel) {
    final e = alignedBeat(hist8, slp, wordSel * 2);
    final o = alignedBeat(hist8, slp, wordSel * 2 + 1);
    return packWord(e, o);
  }

  test('8-position bitslip rotation slides across the {prev,cur} 8-beat window', () {
    // A distinct value per burst beat so any misrotation is caught.
    final hist8 = [
      0x0000, 0x1111, 0x2222, 0x3333, // prev cycle (burst beats 0..3)
      0x4444, 0x5555, 0x6666, 0x7777, // cur cycle  (burst beats 4..7)
    ];
    // slp=0: the aligned burst is the history in order, word0 = {beat0, beat1}
    // packed odd-in-MSB (half-swap fix): word0 = (beat1<<16)|beat0 = 0x11110000.
    expect(selWord(hist8, 0, 0), 0x11110000);
    expect(selWord(hist8, 0, 1), 0x33332222);
    expect(selWord(hist8, 0, 2), 0x55554444);
    expect(selWord(hist8, 0, 3), 0x77776666);
    // slp=1: the window slides ONE beat later, the burst now starts at beat1,
    // and the wrap pulls the previous cycle's beat0 into the tail (position 7).
    expect(selWord(hist8, 1, 0), 0x22221111);
    expect(selWord(hist8, 1, 3), 0x00007777);
    // slp=4: a full cross into the cur cycle: beat0-of-burst is now cur Q0.
    // This is the alignment the OLD same-cycle 4-way rotation could NOT reach.
    expect(selWord(hist8, 4, 0), 0x55554444);
    expect(selWord(hist8, 4, 2), 0x11110000);
  });

  test('some bitslip lands a clean uniform word from a beat-scrambled capture', () {
    // Model the beat-scramble: the gearbox presents the correct 8 burst beats
    // but rotated by an unknown phase k. For a written pattern whose 4 words are
    // all 0x5A5A5A5A (byte-uniform per beat = 0x5A5A per 16-bit beat), the burst
    // beats are all 0x5A5A regardless of rotation, so EVERY bitslip yields the
    // clean word. This models the "5A5A5A5A must read back clean at some slp".
    final uniform = List.filled(8, 0x5A5A);
    for (var slp = 0; slp < 8; slp++) {
      for (var w = 0; w < 4; w++) {
        expect(
          selWord(uniform, slp, w),
          0x5A5A5A5A,
          reason: 'slp=$slp word=$w must be clean 5A5A5A5A',
        );
      }
    }

    // Now a NON-uniform written line (the C0DE discriminator: word w = 0xC0DEwwww).
    // The WRITE packs beat0 = rise = low16 = 0xwwww and beat1 = fall = high16 =
    // 0xC0DE (half-swap fix: the read re-packs odd-in-MSB to restore 0xC0DEwwww).
    // If the capture is rotated by phase k, EXACTLY ONE bitslip (slp = (8 - k) % 8)
    // de-rotates it so all four words read back in-order. Prove the unique bitslip.
    final written = [
      0x0000, 0xC0DE, // word0 = C0DE0000 (beat0 low16=0000, beat1 high16=C0DE)
      0x1111, 0xC0DE, // word1 = C0DE1111
      0x2222, 0xC0DE, // word2 = C0DE2222
      0x3333, 0xC0DE, // word3 = C0DE3333
    ];
    for (var k = 0; k < 8; k++) {
      // Capture rotated LEFT by k (gearbox phase): captured[i] = written[(i+k)%8].
      final captured = [for (var i = 0; i < 8; i++) written[(i + k) % 8]];
      // The de-rotating bitslip.
      final slp = (8 - k) % 8;
      expect(selWord(captured, slp, 0), 0xC0DE0000, reason: 'k=$k slp=$slp w0');
      expect(selWord(captured, slp, 1), 0xC0DE1111, reason: 'k=$k slp=$slp w1');
      expect(selWord(captured, slp, 2), 0xC0DE2222, reason: 'k=$k slp=$slp w2');
      expect(selWord(captured, slp, 3), 0xC0DE3333, reason: 'k=$k slp=$slp w3');
    }
  });
}
