/// DVI 1.0 TMDS encoder model (Figure 3-5), written from the spec.
///
/// Call [encode] once for each pixel clock, in stream order.
class TmdsReference {
  int _cnt = 0;

  static int _ones(int v, int bits) {
    var n = 0;
    for (var i = 0; i < bits; i++) {
      n += (v >> i) & 1;
    }
    return n;
  }

  int encode({required bool de, required int data, required int ctrl}) {
    if (!de) {
      _cnt = 0;
      return const [0x354, 0x0AB, 0x154, 0x2AB][ctrl & 3];
    }
    final n1d = _ones(data, 8);
    final xnor = n1d > 4 || (n1d == 4 && (data & 1) == 0);
    var qm = data & 1;
    for (var i = 1; i < 8; i++) {
      var b = ((qm >> (i - 1)) & 1) ^ ((data >> i) & 1);
      if (xnor) b ^= 1;
      qm |= b << i;
    }
    if (!xnor) qm |= 1 << 8;
    final qm8 = (qm >> 8) & 1;
    final low = qm & 0xFF;
    final n1 = _ones(low, 8);
    final n0 = 8 - n1;
    int q;
    if (_cnt == 0 || n1 == n0) {
      q = ((qm8 ^ 1) << 9) | (qm8 << 8) | (qm8 == 1 ? low : (~low & 0xFF));
      _cnt += qm8 == 1 ? n1 - n0 : n0 - n1;
    } else if ((_cnt > 0 && n1 > n0) || (_cnt < 0 && n0 > n1)) {
      q = (1 << 9) | (qm8 << 8) | (~low & 0xFF);
      _cnt += 2 * qm8 + n0 - n1;
    } else {
      q = (qm8 << 8) | low;
      _cnt += -2 * (1 - qm8) + n1 - n0;
    }
    return q;
  }
}
