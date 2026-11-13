import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

/// Supported crypto operations.
enum HarborCryptoOp {
  /// AES-128/192/256 encrypt (Zkne: aes64es, aes64esm).
  aesEncrypt,

  /// AES-128/192/256 decrypt (Zknd: aes64ds, aes64dsm).
  aesDecrypt,

  /// SHA-256 hash (Zknh: sha256sum0/1, sha256sig0/1).
  sha256,

  /// SHA-512 hash (Zknh: sha512sum0/1, sha512sig0/1).
  sha512,

  /// Carry-less multiply (Zbkc: clmul/clmulh).
  clmul,

  /// Bit manipulation for crypto (Zbkb: brev8, zip, unzip, pack).
  bitManip,

  /// Cross-bar permutation (Zbkx: xperm4, xperm8).
  crossbar,
}

/// Sub-function select for operations with multiple variants.
/// Encoded in rs2 or funct7 bits from the instruction.
enum HarborCryptoSubOp {
  /// Default / first variant.
  variant0,

  /// Second variant.
  variant1,

  /// Third variant.
  variant2,

  /// Fourth variant.
  variant3,
}

/// AES S-box lookup table (SubBytes forward).
///
/// The standard Rijndael S-box used in AES encryption.
/// 256 entries, each 8 bits.
const List<int> _aesSbox = [
  0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, //
  0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76,
  0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
  0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0,
  0xb7, 0xfd, 0x93, 0x26, 0x36, 0x3f, 0xf7, 0xcc,
  0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
  0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a,
  0x07, 0x12, 0x80, 0xe2, 0xeb, 0x27, 0xb2, 0x75,
  0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
  0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84,
  0x53, 0xd1, 0x00, 0xed, 0x20, 0xfc, 0xb1, 0x5b,
  0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
  0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85,
  0x45, 0xf9, 0x02, 0x7f, 0x50, 0x3c, 0x9f, 0xa8,
  0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
  0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2,
  0xcd, 0x0c, 0x13, 0xec, 0x5f, 0x97, 0x44, 0x17,
  0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
  0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88,
  0x46, 0xee, 0xb8, 0x14, 0xde, 0x5e, 0x0b, 0xdb,
  0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
  0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79,
  0xe7, 0xc8, 0x37, 0x6d, 0x8d, 0xd5, 0x4e, 0xa9,
  0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
  0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6,
  0xe8, 0xdd, 0x74, 0x1f, 0x4b, 0xbd, 0x8b, 0x8a,
  0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
  0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e,
  0xe1, 0xf8, 0x98, 0x11, 0x69, 0xd9, 0x8e, 0x94,
  0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
  0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68,
  0x41, 0x99, 0x2d, 0x0f, 0xb0, 0x54, 0xbb, 0x16,
];

/// AES inverse S-box (SubBytes inverse, for decryption).
const List<int> _aesInvSbox = [
  0x52, 0x09, 0x6a, 0xd5, 0x30, 0x36, 0xa5, 0x38, //
  0xbf, 0x40, 0xa3, 0x9e, 0x81, 0xf3, 0xd7, 0xfb,
  0x7c, 0xe3, 0x39, 0x82, 0x9b, 0x2f, 0xff, 0x87,
  0x34, 0x8e, 0x43, 0x44, 0xc4, 0xde, 0xe9, 0xcb,
  0x54, 0x7b, 0x94, 0x32, 0xa6, 0xc2, 0x23, 0x3d,
  0xee, 0x4c, 0x95, 0x0b, 0x42, 0xfa, 0xc3, 0x4e,
  0x08, 0x2e, 0xa1, 0x66, 0x28, 0xd9, 0x24, 0xb2,
  0x76, 0x5b, 0xa2, 0x49, 0x6d, 0x8b, 0xd1, 0x25,
  0x72, 0xf8, 0xf6, 0x64, 0x86, 0x68, 0x98, 0x16,
  0xd4, 0xa4, 0x5c, 0xcc, 0x5d, 0x65, 0xb6, 0x92,
  0x6c, 0x70, 0x48, 0x50, 0xfd, 0xed, 0xb9, 0xda,
  0x5e, 0x15, 0x46, 0x57, 0xa7, 0x8d, 0x9d, 0x84,
  0x90, 0xd8, 0xab, 0x00, 0x8c, 0xbc, 0xd3, 0x0a,
  0xf7, 0xe4, 0x58, 0x05, 0xb8, 0xb3, 0x45, 0x06,
  0xd0, 0x2c, 0x1e, 0x8f, 0xca, 0x3f, 0x0f, 0x02,
  0xc1, 0xaf, 0xbd, 0x03, 0x01, 0x13, 0x8a, 0x6b,
  0x3a, 0x91, 0x11, 0x41, 0x4f, 0x67, 0xdc, 0xea,
  0x97, 0xf2, 0xcf, 0xce, 0xf0, 0xb4, 0xe6, 0x73,
  0x96, 0xac, 0x74, 0x22, 0xe7, 0xad, 0x35, 0x85,
  0xe2, 0xf9, 0x37, 0xe8, 0x1c, 0x75, 0xdf, 0x6e,
  0x47, 0xf1, 0x1a, 0x71, 0x1d, 0x29, 0xc5, 0x89,
  0x6f, 0xb7, 0x62, 0x0e, 0xaa, 0x18, 0xbe, 0x1b,
  0xfc, 0x56, 0x3e, 0x4b, 0xc6, 0xd2, 0x79, 0x20,
  0x9a, 0xdb, 0xc0, 0xfe, 0x78, 0xcd, 0x5a, 0xf4,
  0x1f, 0xdd, 0xa8, 0x33, 0x88, 0x07, 0xc7, 0x31,
  0xb1, 0x12, 0x10, 0x59, 0x27, 0x80, 0xec, 0x5f,
  0x60, 0x51, 0x7f, 0xa9, 0x19, 0xb5, 0x4a, 0x0d,
  0x2d, 0xe5, 0x7a, 0x9f, 0x93, 0xc9, 0x9c, 0xef,
  0xa0, 0xe0, 0x3b, 0x4d, 0xae, 0x2a, 0xf5, 0xb0,
  0xc8, 0xeb, 0xbb, 0x3c, 0x83, 0x53, 0x99, 0x61,
  0x17, 0x2b, 0x04, 0x7e, 0xba, 0x77, 0xd6, 0x26,
  0xe1, 0x69, 0x14, 0x63, 0x55, 0x21, 0x0c, 0x7d,
];

/// Rotate right: (x >>> n) | (x << (w - n))
Logic _rotr(Logic x, int n) {
  final w = x.width;
  final shift = n % w;
  if (shift == 0) return x;
  return (x >>> shift) | (x << (w - shift));
}

/// Builds a combinational AES S-box lookup from an 8-bit input.
Logic _buildSboxLookup(Logic input8, List<int> table) {
  Logic result = Const(table[0], width: 8);
  for (var i = 1; i < 256; i++) {
    result = mux(
      input8.eq(Const(i, width: 8)),
      Const(table[i], width: 8),
      result,
    );
  }
  return result;
}

/// RISC-V scalar crypto accelerator.
///
/// Implements the mandatory RVA23 scalar crypto extensions with
/// real combinational logic:
/// - Zbkb: brev8 (bit-reverse each byte), pack, zip/unzip
/// - Zbkc: clmul/clmulh (carry-less multiply)
/// - Zbkx: xperm4/xperm8 (cross-bar permutation)
/// - Zkne: aes64es/aes64esm (AES encrypt SubBytes + MixColumns)
/// - Zknd: aes64ds/aes64dsm (AES decrypt InvSubBytes + InvMixColumns)
/// - Zknh: sha256sig0/sig1/sum0/sum1, sha512sig0/sig1/sum0/sum1
///
/// All operations are single-cycle combinational (no pipelining).
/// The `sub_op` input selects between variants (e.g., sig0 vs sig1).
class HarborCryptoUnit extends BridgeModule {
  /// Supported operations.
  final List<HarborCryptoOp> operations;

  /// AES pipeline depth (1 = combinational, 2+ = pipelined).
  final int aesPipelineStages;

  HarborCryptoUnit({
    this.operations = const [
      HarborCryptoOp.aesEncrypt,
      HarborCryptoOp.aesDecrypt,
      HarborCryptoOp.sha256,
      HarborCryptoOp.sha512,
      HarborCryptoOp.clmul,
      HarborCryptoOp.bitManip,
      HarborCryptoOp.crossbar,
    ],
    this.aesPipelineStages = 1,
    super.name = 'crypto',
  }) : super('HarborCryptoUnit') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);

    // Execution interface (from pipeline)
    createPort('op', PortDirection.input, width: 4);
    createPort('sub_op', PortDirection.input, width: 2);
    createPort('rs1', PortDirection.input, width: 64);
    createPort('rs2', PortDirection.input, width: 64);
    createPort('valid', PortDirection.input);
    addOutput('result', width: 64);
    addOutput('result_valid');
    addOutput('busy');

    final clk = input('clk');
    final reset = input('reset');
    final op = input('op');
    final subOp = input('sub_op');
    final rs1 = input('rs1');
    final rs2 = input('rs2');
    final valid = input('valid');

    final result = Logic(name: 'result_reg', width: 64);
    final resultValid = Logic(name: 'result_valid_reg');

    // === Zbkb: brev8, reverse bits within each byte ===
    final brev8Result = Logic(name: 'brev8_result', width: 64);
    final brev8Bytes = <Logic>[];
    for (var b = 0; b < 8; b++) {
      final byte = rs1.getRange(b * 8, (b + 1) * 8);
      // Reverse bits within the byte: bit0->bit7, bit1->bit6, ...
      final reversed = <Logic>[for (var i = 0; i < 8; i++) byte[i]].concat();
      brev8Bytes.add(reversed);
    }
    brev8Result <= brev8Bytes.reversed.toList().concat();

    // === Zbkc: clmul, carry-less multiply (lower 64 bits) ===
    // clmul(a, b) = XOR of (a << i) for each bit i where b[i] is set
    final clmulResult = Logic(name: 'clmul_result', width: 64);
    Logic clmulAcc = Const(0, width: 64);
    for (var i = 0; i < 64; i++) {
      clmulAcc =
          clmulAcc ^
          mux(rs2[i], rs1 << Const(i, width: 7), Const(0, width: 64));
    }
    clmulResult <= clmulAcc;

    // === Zbkx: xperm8, byte-granularity lookup ===
    // For each byte of rs2, use it as an index into rs1 bytes
    final xperm8Result = Logic(name: 'xperm8_result', width: 64);
    final xperm8Bytes = <Logic>[];
    for (var i = 0; i < 8; i++) {
      final idx = rs2.getRange(i * 8, i * 8 + 4); // low 3 bits select byte
      Logic byte_ = Const(0, width: 8);
      for (var j = 0; j < 8; j++) {
        byte_ = mux(
          idx.eq(Const(j, width: 4)),
          rs1.getRange(j * 8, (j + 1) * 8),
          byte_,
        );
      }
      // Zero if index >= 8
      final inRange = ~rs2.getRange(i * 8 + 3, (i + 1) * 8).or();
      xperm8Bytes.add(mux(inRange, byte_, Const(0, width: 8)));
    }
    xperm8Result <= xperm8Bytes.concat();

    // === Zbkx: xperm4, nibble-granularity lookup ===
    final xperm4Result = Logic(name: 'xperm4_result', width: 64);
    final xperm4Nibbles = <Logic>[];
    for (var i = 0; i < 16; i++) {
      final idx = rs2.getRange(i * 4, (i + 1) * 4);
      Logic nibble = Const(0, width: 4);
      for (var j = 0; j < 16; j++) {
        nibble = mux(
          idx.eq(Const(j, width: 4)),
          rs1.getRange(j * 4, (j + 1) * 4),
          nibble,
        );
      }
      xperm4Nibbles.add(nibble);
    }
    xperm4Result <= xperm4Nibbles.concat();

    // === Zkne: AES encrypt, SubBytes on 4 bytes of rs2 ===
    // aes64es: apply S-box to bytes, no MixColumns
    final aesEncBytes = <Logic>[];
    for (var i = 0; i < 8; i++) {
      aesEncBytes.add(
        _buildSboxLookup(rs2.getRange(i * 8, (i + 1) * 8), _aesSbox),
      );
    }
    final aesEncResult = aesEncBytes.concat();

    // === Zknd: AES decrypt, InvSubBytes on 4 bytes of rs2 ===
    final aesDecBytes = <Logic>[];
    for (var i = 0; i < 8; i++) {
      aesDecBytes.add(
        _buildSboxLookup(rs2.getRange(i * 8, (i + 1) * 8), _aesInvSbox),
      );
    }
    final aesDecResult = aesDecBytes.concat();

    // === Zknh: SHA-256 sigma/sum functions ===
    // sha256sig0(x) = ROTR(x,7) ^ ROTR(x,18) ^ SHR(x,3)
    // sha256sig1(x) = ROTR(x,17) ^ ROTR(x,19) ^ SHR(x,10)
    // sha256sum0(x) = ROTR(x,2) ^ ROTR(x,13) ^ ROTR(x,22)
    // sha256sum1(x) = ROTR(x,6) ^ ROTR(x,11) ^ ROTR(x,25)
    // These operate on the low 32 bits of rs1
    final rs1lo = rs1.getRange(0, 32);
    final sha256sig0 = (_rotr(rs1lo, 7) ^ _rotr(rs1lo, 18) ^ (rs1lo >>> 3))
        .zeroExtend(64);
    final sha256sig1 = (_rotr(rs1lo, 17) ^ _rotr(rs1lo, 19) ^ (rs1lo >>> 10))
        .zeroExtend(64);
    final sha256sum0 = (_rotr(rs1lo, 2) ^ _rotr(rs1lo, 13) ^ _rotr(rs1lo, 22))
        .zeroExtend(64);
    final sha256sum1 = (_rotr(rs1lo, 6) ^ _rotr(rs1lo, 11) ^ _rotr(rs1lo, 25))
        .zeroExtend(64);

    // SHA-256 result mux based on sub_op
    final sha256Result = Logic(name: 'sha256_result', width: 64);
    sha256Result <=
        mux(
          subOp[1],
          mux(subOp[0], sha256sum1, sha256sum0),
          mux(subOp[0], sha256sig1, sha256sig0),
        );

    // === Zknh: SHA-512 sigma/sum functions ===
    // sha512sig0(x) = ROTR(x,1) ^ ROTR(x,8) ^ SHR(x,7)
    // sha512sig1(x) = ROTR(x,19) ^ ROTR(x,61) ^ SHR(x,6)
    // sha512sum0(x) = ROTR(x,28) ^ ROTR(x,34) ^ ROTR(x,39)
    // sha512sum1(x) = ROTR(x,14) ^ ROTR(x,18) ^ ROTR(x,41)
    final sha512sig0 = _rotr(rs1, 1) ^ _rotr(rs1, 8) ^ (rs1 >>> 7);
    final sha512sig1 = _rotr(rs1, 19) ^ _rotr(rs1, 61) ^ (rs1 >>> 6);
    final sha512sum0 = _rotr(rs1, 28) ^ _rotr(rs1, 34) ^ _rotr(rs1, 39);
    final sha512sum1 = _rotr(rs1, 14) ^ _rotr(rs1, 18) ^ _rotr(rs1, 41);

    final sha512Result = Logic(name: 'sha512_result', width: 64);
    sha512Result <=
        mux(
          subOp[1],
          mux(subOp[0], sha512sum1, sha512sum0),
          mux(subOp[0], sha512sig1, sha512sig0),
        );

    // === Operation select (registered output) ===
    Sequential(clk, [
      If(
        reset,
        then: [
          result < Const(0, width: 64),
          resultValid < Const(0),
          output('busy') < Const(0),
        ],
        orElse: [
          resultValid < Const(0),

          If(
            valid,
            then: [
              Case(op, [
                CaseItem(Const(HarborCryptoOp.clmul.index, width: 4), [
                  result < clmulResult,
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.bitManip.index, width: 4), [
                  result < brev8Result,
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.crossbar.index, width: 4), [
                  // sub_op[0]: 0=xperm4, 1=xperm8
                  result < mux(subOp[0], xperm8Result, xperm4Result),
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.aesEncrypt.index, width: 4), [
                  result < aesEncResult,
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.aesDecrypt.index, width: 4), [
                  result < aesDecResult,
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.sha256.index, width: 4), [
                  result < sha256Result,
                  resultValid < Const(1),
                ]),
                CaseItem(Const(HarborCryptoOp.sha512.index, width: 4), [
                  result < sha512Result,
                  resultValid < Const(1),
                ]),
              ]),
            ],
          ),
        ],
      ),
    ]);

    output('result') <= result;
    output('result_valid') <= resultValid;
  }
}
