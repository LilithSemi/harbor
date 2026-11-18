import 'package:harbor/harbor.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

/// Pure combinational test of crypto operations.
/// Creates a Module, builds it, then puts values and reads results.
class CryptoTB extends Module {
  late final Logic result;

  CryptoTB(String name) : super(name: name) {
    final op = addInput('op', Logic(width: 4), width: 4);
    final rs1 = addInput('rs1', Logic(width: 64), width: 64);
    final rs2 = addInput('rs2', Logic(width: 64), width: 64);
    result = addOutput('result', width: 64);

    // brev8: reverse bits within each byte
    final brev8Bytes = <Logic>[];
    for (var b = 0; b < 8; b++) {
      final byte = rs1.getRange(b * 8, (b + 1) * 8);
      brev8Bytes.add([for (var i = 0; i < 8; i++) byte[i]].concat());
    }
    final brev8Out = brev8Bytes.reversed.toList().concat();

    // clmul
    Logic clmulAcc = Const(0, width: 64);
    for (var i = 0; i < 64; i++) {
      clmulAcc =
          clmulAcc ^
          mux(rs2[i], rs1 << Const(i, width: 7), Const(0, width: 64));
    }

    // xperm8
    final xp8 = <Logic>[];
    for (var i = 0; i < 8; i++) {
      final idx = rs2.getRange(i * 8, i * 8 + 4);
      Logic b = Const(0, width: 8);
      for (var j = 0; j < 8; j++) {
        b = mux(
          idx.eq(Const(j, width: 4)),
          rs1.getRange(j * 8, (j + 1) * 8),
          b,
        );
      }
      final inR = ~rs2.getRange(i * 8 + 3, (i + 1) * 8).or();
      xp8.add(mux(inR, b, Const(0, width: 8)));
    }
    final xp8Out = xp8.concat();

    // AES S-box (byte 0 of rs2)
    const sbox = [
      0x63,
      0x7c,
      0x77,
      0x7b,
      0xf2,
      0x6b,
      0x6f,
      0xc5,
      0x30,
      0x01,
      0x67,
      0x2b,
      0xfe,
      0xd7,
      0xab,
      0x76,
      0xca,
      0x82,
      0xc9,
      0x7d,
      0xfa,
      0x59,
      0x47,
      0xf0,
      0xad,
      0xd4,
      0xa2,
      0xaf,
      0x9c,
      0xa4,
      0x72,
      0xc0,
      0xb7,
      0xfd,
      0x93,
      0x26,
      0x36,
      0x3f,
      0xf7,
      0xcc,
      0x34,
      0xa5,
      0xe5,
      0xf1,
      0x71,
      0xd8,
      0x31,
      0x15,
      0x04,
      0xc7,
      0x23,
      0xc3,
      0x18,
      0x96,
      0x05,
      0x9a,
      0x07,
      0x12,
      0x80,
      0xe2,
      0xeb,
      0x27,
      0xb2,
      0x75,
      0x09,
      0x83,
      0x2c,
      0x1a,
      0x1b,
      0x6e,
      0x5a,
      0xa0,
      0x52,
      0x3b,
      0xd6,
      0xb3,
      0x29,
      0xe3,
      0x2f,
      0x84,
      0x53,
      0xd1,
      0x00,
      0xed,
      0x20,
      0xfc,
      0xb1,
      0x5b,
      0x6a,
      0xcb,
      0xbe,
      0x39,
      0x4a,
      0x4c,
      0x58,
      0xcf,
      0xd0,
      0xef,
      0xaa,
      0xfb,
      0x43,
      0x4d,
      0x33,
      0x85,
      0x45,
      0xf9,
      0x02,
      0x7f,
      0x50,
      0x3c,
      0x9f,
      0xa8,
      0x51,
      0xa3,
      0x40,
      0x8f,
      0x92,
      0x9d,
      0x38,
      0xf5,
      0xbc,
      0xb6,
      0xda,
      0x21,
      0x10,
      0xff,
      0xf3,
      0xd2,
      0xcd,
      0x0c,
      0x13,
      0xec,
      0x5f,
      0x97,
      0x44,
      0x17,
      0xc4,
      0xa7,
      0x7e,
      0x3d,
      0x64,
      0x5d,
      0x19,
      0x73,
      0x60,
      0x81,
      0x4f,
      0xdc,
      0x22,
      0x2a,
      0x90,
      0x88,
      0x46,
      0xee,
      0xb8,
      0x14,
      0xde,
      0x5e,
      0x0b,
      0xdb,
      0xe0,
      0x32,
      0x3a,
      0x0a,
      0x49,
      0x06,
      0x24,
      0x5c,
      0xc2,
      0xd3,
      0xac,
      0x62,
      0x91,
      0x95,
      0xe4,
      0x79,
      0xe7,
      0xc8,
      0x37,
      0x6d,
      0x8d,
      0xd5,
      0x4e,
      0xa9,
      0x6c,
      0x56,
      0xf4,
      0xea,
      0x65,
      0x7a,
      0xae,
      0x08,
      0xba,
      0x78,
      0x25,
      0x2e,
      0x1c,
      0xa6,
      0xb4,
      0xc6,
      0xe8,
      0xdd,
      0x74,
      0x1f,
      0x4b,
      0xbd,
      0x8b,
      0x8a,
      0x70,
      0x3e,
      0xb5,
      0x66,
      0x48,
      0x03,
      0xf6,
      0x0e,
      0x61,
      0x35,
      0x57,
      0xb9,
      0x86,
      0xc1,
      0x1d,
      0x9e,
      0xe1,
      0xf8,
      0x98,
      0x11,
      0x69,
      0xd9,
      0x8e,
      0x94,
      0x9b,
      0x1e,
      0x87,
      0xe9,
      0xce,
      0x55,
      0x28,
      0xdf,
      0x8c,
      0xa1,
      0x89,
      0x0d,
      0xbf,
      0xe6,
      0x42,
      0x68,
      0x41,
      0x99,
      0x2d,
      0x0f,
      0xb0,
      0x54,
      0xbb,
      0x16,
    ];
    const isbox = [
      0x52,
      0x09,
      0x6a,
      0xd5,
      0x30,
      0x36,
      0xa5,
      0x38,
      0xbf,
      0x40,
      0xa3,
      0x9e,
      0x81,
      0xf3,
      0xd7,
      0xfb,
      0x7c,
      0xe3,
      0x39,
      0x82,
      0x9b,
      0x2f,
      0xff,
      0x87,
      0x34,
      0x8e,
      0x43,
      0x44,
      0xc4,
      0xde,
      0xe9,
      0xcb,
      0x54,
      0x7b,
      0x94,
      0x32,
      0xa6,
      0xc2,
      0x23,
      0x3d,
      0xee,
      0x4c,
      0x95,
      0x0b,
      0x42,
      0xfa,
      0xc3,
      0x4e,
      0x08,
      0x2e,
      0xa1,
      0x66,
      0x28,
      0xd9,
      0x24,
      0xb2,
      0x76,
      0x5b,
      0xa2,
      0x49,
      0x6d,
      0x8b,
      0xd1,
      0x25,
      0x72,
      0xf8,
      0xf6,
      0x64,
      0x86,
      0x68,
      0x98,
      0x16,
      0xd4,
      0xa4,
      0x5c,
      0xcc,
      0x5d,
      0x65,
      0xb6,
      0x92,
      0x6c,
      0x70,
      0x48,
      0x50,
      0xfd,
      0xed,
      0xb9,
      0xda,
      0x5e,
      0x15,
      0x46,
      0x57,
      0xa7,
      0x8d,
      0x9d,
      0x84,
      0x90,
      0xd8,
      0xab,
      0x00,
      0x8c,
      0xbc,
      0xd3,
      0x0a,
      0xf7,
      0xe4,
      0x58,
      0x05,
      0xb8,
      0xb3,
      0x45,
      0x06,
      0xd0,
      0x2c,
      0x1e,
      0x8f,
      0xca,
      0x3f,
      0x0f,
      0x02,
      0xc1,
      0xaf,
      0xbd,
      0x03,
      0x01,
      0x13,
      0x8a,
      0x6b,
      0x3a,
      0x91,
      0x11,
      0x41,
      0x4f,
      0x67,
      0xdc,
      0xea,
      0x97,
      0xf2,
      0xcf,
      0xce,
      0xf0,
      0xb4,
      0xe6,
      0x73,
      0x96,
      0xac,
      0x74,
      0x22,
      0xe7,
      0xad,
      0x35,
      0x85,
      0xe2,
      0xf9,
      0x37,
      0xe8,
      0x1c,
      0x75,
      0xdf,
      0x6e,
      0x47,
      0xf1,
      0x1a,
      0x71,
      0x1d,
      0x29,
      0xc5,
      0x89,
      0x6f,
      0xb7,
      0x62,
      0x0e,
      0xaa,
      0x18,
      0xbe,
      0x1b,
      0xfc,
      0x56,
      0x3e,
      0x4b,
      0xc6,
      0xd2,
      0x79,
      0x20,
      0x9a,
      0xdb,
      0xc0,
      0xfe,
      0x78,
      0xcd,
      0x5a,
      0xf4,
      0x1f,
      0xdd,
      0xa8,
      0x33,
      0x88,
      0x07,
      0xc7,
      0x31,
      0xb1,
      0x12,
      0x10,
      0x59,
      0x27,
      0x80,
      0xec,
      0x5f,
      0x60,
      0x51,
      0x7f,
      0xa9,
      0x19,
      0xb5,
      0x4a,
      0x0d,
      0x2d,
      0xe5,
      0x7a,
      0x9f,
      0x93,
      0xc9,
      0x9c,
      0xef,
      0xa0,
      0xe0,
      0x3b,
      0x4d,
      0xae,
      0x2a,
      0xf5,
      0xb0,
      0xc8,
      0xeb,
      0xbb,
      0x3c,
      0x83,
      0x53,
      0x99,
      0x61,
      0x17,
      0x2b,
      0x04,
      0x7e,
      0xba,
      0x77,
      0xd6,
      0x26,
      0xe1,
      0x69,
      0x14,
      0x63,
      0x55,
      0x21,
      0x0c,
      0x7d,
    ];
    final rs2b = rs2.getRange(0, 8);
    Logic aesFwd = Const(0, width: 8);
    Logic aesInv = Const(0, width: 8);
    for (var i = 0; i < 256; i++) {
      aesFwd = mux(
        rs2b.eq(Const(i, width: 8)),
        Const(sbox[i], width: 8),
        aesFwd,
      );
      aesInv = mux(
        rs2b.eq(Const(i, width: 8)),
        Const(isbox[i], width: 8),
        aesInv,
      );
    }

    // SHA-256 sig0
    final lo = rs1.getRange(0, 32);
    final sha256 =
        ((lo >>> 7) | (lo << 25)) ^ ((lo >>> 18) | (lo << 14)) ^ (lo >>> 3);

    // SHA-512 sig0
    final sha512 =
        ((rs1 >>> 1) | (rs1 << 63)) ^ ((rs1 >>> 8) | (rs1 << 56)) ^ (rs1 >>> 7);

    // Mux by op
    result <=
        mux(
          op.eq(Const(HarborCryptoOp.bitManip.index, width: 4)),
          brev8Out,
          mux(
            op.eq(Const(HarborCryptoOp.clmul.index, width: 4)),
            clmulAcc,
            mux(
              op.eq(Const(HarborCryptoOp.crossbar.index, width: 4)),
              xp8Out,
              mux(
                op.eq(Const(HarborCryptoOp.aesEncrypt.index, width: 4)),
                aesFwd.zeroExtend(64),
                mux(
                  op.eq(Const(HarborCryptoOp.aesDecrypt.index, width: 4)),
                  aesInv.zeroExtend(64),
                  mux(
                    op.eq(Const(HarborCryptoOp.sha256.index, width: 4)),
                    sha256.zeroExtend(64),
                    mux(
                      op.eq(Const(HarborCryptoOp.sha512.index, width: 4)),
                      sha512,
                      Const(0, width: 64),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
  }

  int run(int opIdx, int rs1, int rs2) {
    input('op').put(opIdx);
    input('rs1').put(rs1);
    input('rs2').put(rs2);
    return result.value.isValid ? result.value.toInt() : -1;
  }
}

void main() {
  late CryptoTB tb;

  setUp(() async {
    tb = CryptoTB('crypto_tb');
    await tb.build();
  });

  test('brev8: 0x80 -> 0x01', () {
    expect(tb.run(HarborCryptoOp.bitManip.index, 0x80, 0) & 0xFF, equals(0x01));
  });
  test('brev8: 0xFF -> 0xFF', () {
    expect(tb.run(HarborCryptoOp.bitManip.index, 0xFF, 0) & 0xFF, equals(0xFF));
  });
  test('brev8: 0x0F -> 0xF0', () {
    expect(tb.run(HarborCryptoOp.bitManip.index, 0x0F, 0) & 0xFF, equals(0xF0));
  });
  test('brev8: 0x00 -> 0x00', () {
    expect(tb.run(HarborCryptoOp.bitManip.index, 0x00, 0) & 0xFF, equals(0x00));
  });
  test('clmul(0,x)=0', () {
    expect(tb.run(HarborCryptoOp.clmul.index, 0, 0x1234), equals(0));
  });
  test('clmul(x,1)=x', () {
    expect(tb.run(HarborCryptoOp.clmul.index, 0xABCD, 1), equals(0xABCD));
  });
  test('clmul(3,3)=5', () {
    expect(tb.run(HarborCryptoOp.clmul.index, 3, 3), equals(5));
  });
  test('xperm8 broadcast byte 0', () {
    expect(
      tb.run(HarborCryptoOp.crossbar.index, 0xAA, 0),
      equals(0xAAAAAAAAAAAAAAAA),
    );
  });
  test('AES sbox(0x00)=0x63', () {
    expect(
      tb.run(HarborCryptoOp.aesEncrypt.index, 0, 0x00) & 0xFF,
      equals(0x63),
    );
  });
  test('AES sbox(0x01)=0x7C', () {
    expect(
      tb.run(HarborCryptoOp.aesEncrypt.index, 0, 0x01) & 0xFF,
      equals(0x7C),
    );
  });
  test('AES inv_sbox(0x63)=0x00', () {
    expect(
      tb.run(HarborCryptoOp.aesDecrypt.index, 0, 0x63) & 0xFF,
      equals(0x00),
    );
  });
  test('AES roundtrip 0x42', () {
    final enc = tb.run(HarborCryptoOp.aesEncrypt.index, 0, 0x42) & 0xFF;
    final dec = tb.run(HarborCryptoOp.aesDecrypt.index, 0, enc) & 0xFF;
    expect(dec, equals(0x42));
  });
  test('SHA256 sig0(0)=0', () {
    expect(tb.run(HarborCryptoOp.sha256.index, 0, 0), equals(0));
  });
  test('SHA256 sig0(1) nonzero', () {
    expect(tb.run(HarborCryptoOp.sha256.index, 1, 0), isNot(equals(0)));
  });
  test('SHA512 sig0(0)=0', () {
    expect(tb.run(HarborCryptoOp.sha512.index, 0, 0), equals(0));
  });
  test('SHA512 sig0(1) nonzero', () {
    expect(tb.run(HarborCryptoOp.sha512.index, 1, 0), isNot(equals(0)));
  });
}
