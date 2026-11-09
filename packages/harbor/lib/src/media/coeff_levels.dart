import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'coeff_context.dart';
import 'dequant.dart';
import 'od_ec_decoder.dart';

/// Harbor bit-exact AV1 coefficient base-level decoder for TX_4X4, TX_CLASS_2D,
/// luma (the entropy core of `read_coeffs_txb`, through the levels buffer).
///
/// Builds on [HarborEobDecode]'s flow: after txb_skip / eob_pt / eob_extra give
/// `eob`, it walks the scan in reverse decoding each coefficient's base level
/// (3-symbol coeff_base_eob for the eob-1 coeff, else 4-symbol coeff_base) and,
/// when the base saturates (> 2), the coeff_br range-extension loop (up to four
/// 4-symbol reads, breaking when a read is < 3). The per-coefficient entropy
/// context comes from [HarborCoeffContext] over the partially-decoded `levels`
/// buffer, exactly matching libaom's reverse-scan neighbour templates. The real
/// Q0 default CDFs (from [cdf]) are preloaded into od_ec contexts at `start`.
///
/// Output `levels_out` packs the decoded magnitude of position `pos` at
/// `[pos*8 +: 8]` (post base + br, pre golomb/sign), i.e. libaom's `levels`
/// buffer read back in raster order. `done` asserts with `eob`/`all_zero`/
/// `levels_out` valid. This is TX_4X4-2D-luma only for now (the generalization
/// to other sizes/classes/planes follows the same structure).
class HarborCoeffLevels extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// libaom TX_SIZE (TX_4X4 = 0 or TX_8X8 = 1 supported, square, 2D, luma).
  final int txSize;

  static const _scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
  static const _mrow4 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
  static const _mcol4 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
  static const _scan8 = [
    0, 8, 1, 2, 9, 16, 24, 17, 10, 3, 4, 11, 18, 25, 32, 40, //
    33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 48, 56, 49, 42, 35, //
    28, 21, 14, 7, 15, 22, 29, 36, 43, 50, 57, 58, 51, 44, 37, 30, //
    23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54, 61, 62, 55, 63,
  ];
  static const _mrow8 = [
    0, 8, 16, 24, 32, 40, 48, 56, 1, 9, 17, 25, 33, 41, 49, 57, //
    2, 10, 18, 26, 34, 42, 50, 58, 3, 11, 19, 27, 35, 43, 51, 59, //
    4, 12, 20, 28, 36, 44, 52, 60, 5, 13, 21, 29, 37, 45, 53, 61, //
    6, 14, 22, 30, 38, 46, 54, 62, 7, 15, 23, 31, 39, 47, 55, 63,
  ];
  static const _mcol8 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  ];
  // Rectangular TX_4X8 (txSize 5) and TX_8X4 (txSize 6): n = 32 coefficients,
  // column-major scan `pos` values (default 2D scan + mrow/mcol for 1D classes).
  static const _scan4x8 = [
    0, 8, 1, 16, 9, 2, 24, 17, 10, 3, 25, 18, 11, 4, 26, 19, //
    12, 5, 27, 20, 13, 6, 28, 21, 14, 7, 29, 22, 15, 30, 23, 31,
  ];
  static const _scan8x4 = [
    0, 1, 4, 2, 5, 8, 3, 6, 9, 12, 7, 10, 13, 16, 11, 14, //
    17, 20, 15, 18, 21, 24, 19, 22, 25, 28, 23, 26, 29, 27, 30, 31,
  ];
  // Rect 1D scans (value-verified against SW _scanOrders[5]/[6] mrow/mcol):
  // V_DCT (VERT class) reads the mrow scan, H_DCT (HORIZ class) the mcol scan.
  static const _mrow4x8 = [
    0, 8, 16, 24, 1, 9, 17, 25, 2, 10, 18, 26, 3, 11, 19, 27, //
    4, 12, 20, 28, 5, 13, 21, 29, 6, 14, 22, 30, 7, 15, 23, 31,
  ];
  static const _mcol4x8 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  ];
  static const _mrow8x4 = [
    0, 4, 8, 12, 16, 20, 24, 28, 1, 5, 9, 13, 17, 21, 25, 29, //
    2, 6, 10, 14, 18, 22, 26, 30, 3, 7, 11, 15, 19, 23, 27, 31,
  ];
  static const _mcol8x4 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  ];
  // default_scan_16x16 (TX_16X16, 2D), column-major coeff positions.
  static const _scan16 = [
    0,
    16,
    1,
    2,
    17,
    32,
    48,
    33,
    18,
    3,
    4,
    19,
    34,
    49,
    64,
    80,
    65,
    50,
    35,
    20,
    5,
    6,
    21,
    36,
    51,
    66,
    81,
    96,
    112,
    97,
    82,
    67,
    52,
    37,
    22,
    7,
    8,
    23,
    38,
    53,
    68,
    83,
    98,
    113,
    128,
    144,
    129,
    114,
    99,
    84,
    69,
    54,
    39,
    24,
    9,
    10,
    25,
    40,
    55,
    70,
    85,
    100,
    115,
    130,
    145,
    160,
    176,
    161,
    146,
    131,
    116,
    101,
    86,
    71,
    56,
    41,
    26,
    11,
    12,
    27,
    42,
    57,
    72,
    87,
    102,
    117,
    132,
    147,
    162,
    177,
    192,
    208,
    193,
    178,
    163,
    148,
    133,
    118,
    103,
    88,
    73,
    58,
    43,
    28,
    13,
    14,
    29,
    44,
    59,
    74,
    89,
    104,
    119,
    134,
    149,
    164,
    179,
    194,
    209,
    224,
    240,
    225,
    210,
    195,
    180,
    165,
    150,
    135,
    120,
    105,
    90,
    75,
    60,
    45,
    30,
    15,
    31,
    46,
    61,
    76,
    91,
    106,
    121,
    136,
    151,
    166,
    181,
    196,
    211,
    226,
    241,
    242,
    227,
    212,
    197,
    182,
    167,
    152,
    137,
    122,
    107,
    92,
    77,
    62,
    47,
    63,
    78,
    93,
    108,
    123,
    138,
    153,
    168,
    183,
    198,
    213,
    228,
    243,
    244,
    229,
    214,
    199,
    184,
    169,
    154,
    139,
    124,
    109,
    94,
    79,
    95,
    110,
    125,
    140,
    155,
    170,
    185,
    200,
    215,
    230,
    245,
    246,
    231,
    216,
    201,
    186,
    171,
    156,
    141,
    126,
    111,
    127,
    142,
    157,
    172,
    187,
    202,
    217,
    232,
    247,
    248,
    233,
    218,
    203,
    188,
    173,
    158,
    143,
    159,
    174,
    189,
    204,
    219,
    234,
    249,
    250,
    235,
    220,
    205,
    190,
    175,
    191,
    206,
    221,
    236,
    251,
    252,
    237,
    222,
    207,
    223,
    238,
    253,
    254,
    239,
    255,
  ];
  // default_scan_32x32 (TX_32X32, 2D).
  static const _scan32 = [
    0,
    32,
    1,
    2,
    33,
    64,
    96,
    65,
    34,
    3,
    4,
    35,
    66,
    97,
    128,
    160,
    129,
    98,
    67,
    36,
    5,
    6,
    37,
    68,
    99,
    130,
    161,
    192,
    224,
    193,
    162,
    131,
    100,
    69,
    38,
    7,
    8,
    39,
    70,
    101,
    132,
    163,
    194,
    225,
    256,
    288,
    257,
    226,
    195,
    164,
    133,
    102,
    71,
    40,
    9,
    10,
    41,
    72,
    103,
    134,
    165,
    196,
    227,
    258,
    289,
    320,
    352,
    321,
    290,
    259,
    228,
    197,
    166,
    135,
    104,
    73,
    42,
    11,
    12,
    43,
    74,
    105,
    136,
    167,
    198,
    229,
    260,
    291,
    322,
    353,
    384,
    416,
    385,
    354,
    323,
    292,
    261,
    230,
    199,
    168,
    137,
    106,
    75,
    44,
    13,
    14,
    45,
    76,
    107,
    138,
    169,
    200,
    231,
    262,
    293,
    324,
    355,
    386,
    417,
    448,
    480,
    449,
    418,
    387,
    356,
    325,
    294,
    263,
    232,
    201,
    170,
    139,
    108,
    77,
    46,
    15,
    16,
    47,
    78,
    109,
    140,
    171,
    202,
    233,
    264,
    295,
    326,
    357,
    388,
    419,
    450,
    481,
    512,
    544,
    513,
    482,
    451,
    420,
    389,
    358,
    327,
    296,
    265,
    234,
    203,
    172,
    141,
    110,
    79,
    48,
    17,
    18,
    49,
    80,
    111,
    142,
    173,
    204,
    235,
    266,
    297,
    328,
    359,
    390,
    421,
    452,
    483,
    514,
    545,
    576,
    608,
    577,
    546,
    515,
    484,
    453,
    422,
    391,
    360,
    329,
    298,
    267,
    236,
    205,
    174,
    143,
    112,
    81,
    50,
    19,
    20,
    51,
    82,
    113,
    144,
    175,
    206,
    237,
    268,
    299,
    330,
    361,
    392,
    423,
    454,
    485,
    516,
    547,
    578,
    609,
    640,
    672,
    641,
    610,
    579,
    548,
    517,
    486,
    455,
    424,
    393,
    362,
    331,
    300,
    269,
    238,
    207,
    176,
    145,
    114,
    83,
    52,
    21,
    22,
    53,
    84,
    115,
    146,
    177,
    208,
    239,
    270,
    301,
    332,
    363,
    394,
    425,
    456,
    487,
    518,
    549,
    580,
    611,
    642,
    673,
    704,
    736,
    705,
    674,
    643,
    612,
    581,
    550,
    519,
    488,
    457,
    426,
    395,
    364,
    333,
    302,
    271,
    240,
    209,
    178,
    147,
    116,
    85,
    54,
    23,
    24,
    55,
    86,
    117,
    148,
    179,
    210,
    241,
    272,
    303,
    334,
    365,
    396,
    427,
    458,
    489,
    520,
    551,
    582,
    613,
    644,
    675,
    706,
    737,
    768,
    800,
    769,
    738,
    707,
    676,
    645,
    614,
    583,
    552,
    521,
    490,
    459,
    428,
    397,
    366,
    335,
    304,
    273,
    242,
    211,
    180,
    149,
    118,
    87,
    56,
    25,
    26,
    57,
    88,
    119,
    150,
    181,
    212,
    243,
    274,
    305,
    336,
    367,
    398,
    429,
    460,
    491,
    522,
    553,
    584,
    615,
    646,
    677,
    708,
    739,
    770,
    801,
    832,
    864,
    833,
    802,
    771,
    740,
    709,
    678,
    647,
    616,
    585,
    554,
    523,
    492,
    461,
    430,
    399,
    368,
    337,
    306,
    275,
    244,
    213,
    182,
    151,
    120,
    89,
    58,
    27,
    28,
    59,
    90,
    121,
    152,
    183,
    214,
    245,
    276,
    307,
    338,
    369,
    400,
    431,
    462,
    493,
    524,
    555,
    586,
    617,
    648,
    679,
    710,
    741,
    772,
    803,
    834,
    865,
    896,
    928,
    897,
    866,
    835,
    804,
    773,
    742,
    711,
    680,
    649,
    618,
    587,
    556,
    525,
    494,
    463,
    432,
    401,
    370,
    339,
    308,
    277,
    246,
    215,
    184,
    153,
    122,
    91,
    60,
    29,
    30,
    61,
    92,
    123,
    154,
    185,
    216,
    247,
    278,
    309,
    340,
    371,
    402,
    433,
    464,
    495,
    526,
    557,
    588,
    619,
    650,
    681,
    712,
    743,
    774,
    805,
    836,
    867,
    898,
    929,
    960,
    992,
    961,
    930,
    899,
    868,
    837,
    806,
    775,
    744,
    713,
    682,
    651,
    620,
    589,
    558,
    527,
    496,
    465,
    434,
    403,
    372,
    341,
    310,
    279,
    248,
    217,
    186,
    155,
    124,
    93,
    62,
    31,
    63,
    94,
    125,
    156,
    187,
    218,
    249,
    280,
    311,
    342,
    373,
    404,
    435,
    466,
    497,
    528,
    559,
    590,
    621,
    652,
    683,
    714,
    745,
    776,
    807,
    838,
    869,
    900,
    931,
    962,
    993,
    994,
    963,
    932,
    901,
    870,
    839,
    808,
    777,
    746,
    715,
    684,
    653,
    622,
    591,
    560,
    529,
    498,
    467,
    436,
    405,
    374,
    343,
    312,
    281,
    250,
    219,
    188,
    157,
    126,
    95,
    127,
    158,
    189,
    220,
    251,
    282,
    313,
    344,
    375,
    406,
    437,
    468,
    499,
    530,
    561,
    592,
    623,
    654,
    685,
    716,
    747,
    778,
    809,
    840,
    871,
    902,
    933,
    964,
    995,
    996,
    965,
    934,
    903,
    872,
    841,
    810,
    779,
    748,
    717,
    686,
    655,
    624,
    593,
    562,
    531,
    500,
    469,
    438,
    407,
    376,
    345,
    314,
    283,
    252,
    221,
    190,
    159,
    191,
    222,
    253,
    284,
    315,
    346,
    377,
    408,
    439,
    470,
    501,
    532,
    563,
    594,
    625,
    656,
    687,
    718,
    749,
    780,
    811,
    842,
    873,
    904,
    935,
    966,
    997,
    998,
    967,
    936,
    905,
    874,
    843,
    812,
    781,
    750,
    719,
    688,
    657,
    626,
    595,
    564,
    533,
    502,
    471,
    440,
    409,
    378,
    347,
    316,
    285,
    254,
    223,
    255,
    286,
    317,
    348,
    379,
    410,
    441,
    472,
    503,
    534,
    565,
    596,
    627,
    658,
    689,
    720,
    751,
    782,
    813,
    844,
    875,
    906,
    937,
    968,
    999,
    1000,
    969,
    938,
    907,
    876,
    845,
    814,
    783,
    752,
    721,
    690,
    659,
    628,
    597,
    566,
    535,
    504,
    473,
    442,
    411,
    380,
    349,
    318,
    287,
    319,
    350,
    381,
    412,
    443,
    474,
    505,
    536,
    567,
    598,
    629,
    660,
    691,
    722,
    753,
    784,
    815,
    846,
    877,
    908,
    939,
    970,
    1001,
    1002,
    971,
    940,
    909,
    878,
    847,
    816,
    785,
    754,
    723,
    692,
    661,
    630,
    599,
    568,
    537,
    506,
    475,
    444,
    413,
    382,
    351,
    383,
    414,
    445,
    476,
    507,
    538,
    569,
    600,
    631,
    662,
    693,
    724,
    755,
    786,
    817,
    848,
    879,
    910,
    941,
    972,
    1003,
    1004,
    973,
    942,
    911,
    880,
    849,
    818,
    787,
    756,
    725,
    694,
    663,
    632,
    601,
    570,
    539,
    508,
    477,
    446,
    415,
    447,
    478,
    509,
    540,
    571,
    602,
    633,
    664,
    695,
    726,
    757,
    788,
    819,
    850,
    881,
    912,
    943,
    974,
    1005,
    1006,
    975,
    944,
    913,
    882,
    851,
    820,
    789,
    758,
    727,
    696,
    665,
    634,
    603,
    572,
    541,
    510,
    479,
    511,
    542,
    573,
    604,
    635,
    666,
    697,
    728,
    759,
    790,
    821,
    852,
    883,
    914,
    945,
    976,
    1007,
    1008,
    977,
    946,
    915,
    884,
    853,
    822,
    791,
    760,
    729,
    698,
    667,
    636,
    605,
    574,
    543,
    575,
    606,
    637,
    668,
    699,
    730,
    761,
    792,
    823,
    854,
    885,
    916,
    947,
    978,
    1009,
    1010,
    979,
    948,
    917,
    886,
    855,
    824,
    793,
    762,
    731,
    700,
    669,
    638,
    607,
    639,
    670,
    701,
    732,
    763,
    794,
    825,
    856,
    887,
    918,
    949,
    980,
    1011,
    1012,
    981,
    950,
    919,
    888,
    857,
    826,
    795,
    764,
    733,
    702,
    671,
    703,
    734,
    765,
    796,
    827,
    858,
    889,
    920,
    951,
    982,
    1013,
    1014,
    983,
    952,
    921,
    890,
    859,
    828,
    797,
    766,
    735,
    767,
    798,
    829,
    860,
    891,
    922,
    953,
    984,
    1015,
    1016,
    985,
    954,
    923,
    892,
    861,
    830,
    799,
    831,
    862,
    893,
    924,
    955,
    986,
    1017,
    1018,
    987,
    956,
    925,
    894,
    863,
    895,
    926,
    957,
    988,
    1019,
    1020,
    989,
    958,
    927,
    959,
    990,
    1021,
    1022,
    991,
    1023,
  ];
  // bhl = getTxbBwl = log2(adjusted height): TX_4X8 -> 3, TX_8X4 -> 2.
  static const _bhlFor = {0: 2, 1: 3, 2: 4, 3: 5, 4: 5, 5: 3, 6: 2};
  static const _nFor = {0: 16, 1: 64, 2: 256, 3: 1024, 4: 1024, 5: 32, 6: 32};

  static const _bypass = [16384, 0];
  static const _eobOffsetBits = [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
  static const _eobGroupStart = [0, 1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513];

  // od_ec flat context map (identical across sizes, counts are size-invariant).
  static const _ctxSkip = 0;
  static const _ctxEobPt = 1;
  static const _ctxEobExtra0 = 2; // 2..10
  static const _ctxBaseEob0 = 11; // 11..14   (coeff_base_eob ctx 0..3)
  static const _ctxBase0 = 15; // 15..55      (coeff_base ctx 0..40)
  static const _ctxBr0 = 56; // 56..76        (coeff_br ctx 0..20)
  static const _ctxBypass = 77;
  static const _ctxDcSign = 78; // dc_sign ctx 0 (luma)
  static const _ctxExtTx = 79; // ext-tx (readTxType only)
  static const _ctxEobPt1d = 80; // eob_pt for the 1D class (readTxType only)

  // Intra ext-tx CDFs (DC mode, set DTT4_IDTX_1DDCT) + inv map.
  static const _extTxCdf4 = [31233, 24733, 23307, 20017, 9301, 4943, 0];
  static const _extTxCdf8 = [30898, 19026, 18238, 16270, 8998, 5070, 0];
  static const _extTxInv = [9, 0, 10, 11, 3, 1, 2];

  // kfIntra: ext-tx CDF by intra y_mode (kIntraExtTxCdf[1][0][mode]), TX_4X4.
  static const _extTxByMode = [
    [31233, 24733, 23307, 20017, 9301, 4943, 0],
    [32204, 29433, 23059, 21898, 14625, 4674, 0],
    [32096, 29521, 29092, 20786, 13353, 9641, 0],
    [27489, 18883, 17281, 14724, 9241, 2516, 0],
    [28345, 26694, 24783, 22352, 7075, 3470, 0],
    [31282, 28527, 23308, 22106, 16312, 5074, 0],
    [32329, 29930, 29246, 26031, 14710, 9014, 0],
    [31578, 28535, 27913, 21098, 12487, 8391, 0],
    [31723, 28456, 24121, 22609, 14124, 3433, 0],
    [32566, 29034, 28021, 25470, 15641, 8752, 0],
    [32321, 28456, 25949, 23884, 16758, 8910, 0],
    [32491, 28399, 27513, 23863, 16303, 10497, 0],
    [29359, 27332, 22169, 17169, 13081, 8728, 0],
  ];
  // kfIntra 8x8: ext-tx CDF by intra y_mode (kIntraExtTxCdf[1][1][mode]).
  static const _extTxByMode8 = [
    [30898, 19026, 18238, 16270, 8998, 5070, 0],
    [32442, 23972, 18136, 17689, 13496, 5282, 0],
    [32284, 25192, 25056, 18325, 13609, 10177, 0],
    [31642, 17428, 16873, 15745, 11872, 2489, 0],
    [32113, 27914, 27519, 26855, 10669, 5630, 0],
    [31469, 26310, 23883, 23478, 17917, 7271, 0],
    [32457, 27473, 27216, 25883, 16661, 10096, 0],
    [31885, 24709, 24498, 21510, 15479, 11219, 0],
    [32027, 25188, 23450, 22423, 16080, 3722, 0],
    [32658, 25362, 24853, 23573, 16727, 9439, 0],
    [32405, 24794, 23411, 22095, 17139, 8294, 0],
    [32615, 25121, 24656, 22832, 17461, 12772, 0],
    [29257, 26436, 21603, 17433, 13445, 9174, 0],
  ];
  static const _skipCdf = [
    [1097, 0], [16253, 0], [28192, 0], // by skip_ctx (above+left skip)
  ];
  // default_angle_delta_cdf (ICDF), 8 directional modes (V..D67) x 7 syms.
  static const _angleCdf = [
    [30588, 27736, 25201, 9992, 5779, 2551, 0],
    [30467, 27160, 23967, 9281, 5794, 2438, 0],
    [28988, 21750, 19069, 13414, 9685, 1482, 0],
    [28187, 21542, 17621, 15630, 10934, 4371, 0],
    [31031, 21841, 18259, 13180, 10023, 3945, 0],
    [30104, 22592, 20283, 15118, 11168, 2273, 0],
    [30528, 21672, 17315, 12427, 10207, 3851, 0],
    [29163, 22340, 20309, 15092, 11524, 2113, 0],
  ];
  static const _intraModeContext = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];

  /// libaom TX_CLASS (0 = 2D, 1 = HORIZ, 2 = VERT). HORIZ/VERT only at TX_4X4.
  /// Ignored when [readTxType] (the class is derived from the decoded tx_type).
  final int txClass;

  /// Plane type (0 = luma, 1 = chroma). Selects the per-plane CDF slices.
  final int planeType;

  /// When set, read the intra ext-tx type after txb_skip and derive the
  /// tx_class / scan at runtime (TX_4X4 luma only). The decoded type appears on
  /// the `tx_type` output.
  final bool readTxType;

  /// When set, decode a full keyframe intra LUMA block (TX_4X4, monochrome,
  /// cdef/delta/intrabc/filter-intra off): block_skip then y_mode, then (if not
  /// skipped) the coefficient path with the ext-tx CDF selected by y_mode.
  /// Implies [readTxType]. Outputs `y_mode` and `block_skip`.
  final bool kfIntra;

  /// Base-qindex CDF set (0..3), selected by base_qindex band in a real frame.
  /// Picks the kAv1...CdfQ{qband} default tables.
  final int qband;

  HarborCoeffLevels({
    this.maxBytes = 32,
    this.txSize = 0,
    this.txClass = 0,
    this.planeType = 0,
    this.readTxType = false,
    this.kfIntra = false,
    this.qband = 0,
    String? name,
  }) : assert(qband >= 0 && qband < 4, 'qband 0..3'),
       assert(
         txSize == 0 ||
             txSize == 1 ||
             txSize == 2 ||
             txSize == 3 ||
             txSize == 4 ||
             txSize == 5 ||
             txSize == 6,
         'TX_4X4 / 8X8 / 16X16 / 32X32 / 64X64 / 4X8 / 8X4 only',
       ),
       // rect (TX_4X8 / TX_8X4) and TX_16X16 currently only have Q0 eob CDFs.
       assert(
         (txSize != 5 &&
                 txSize != 6 &&
                 txSize != 2 &&
                 txSize != 3 &&
                 txSize != 4) ||
             qband == 0,
         'rect / TX_16X16 / TX_32X32 / TX_64X64 only at qband 0',
       ),
       assert(txClass == 0 || txSize == 0, 'HORIZ/VERT only at TX_4X4'),
       assert(planeType == 0 || planeType == 1, 'luma / chroma'),
       assert(
         !readTxType ||
             (txClass == 0 &&
                 planeType == 0 &&
                 (txSize == 0 || txSize == 1 || txSize == 5 || txSize == 6)),
         'readTxType: luma 2D-config only (TX_4X4 / TX_8X8 / TX_4X8 / TX_8X4)',
       ),
       assert(
         !kfIntra || ((txSize == 0 || txSize == 1) && readTxType),
         'kfIntra: TX_4X4 / TX_8X8 + readTxType (8x8 non-directional: angle '
         'delta not decoded)',
       ),
       super(
         'HarborCoeffLevels',
         name:
             name ??
             'coeff_levels_${txSize}_${txClass}_${planeType}_$readTxType',
       ) {
    // per-size/class/plane geometry + CDF slices (square)
    final class2d = txClass == 0;
    final pl = planeType;
    // base-qindex CDF set selection (Q0..Q3).
    final skipT = [
      cdf.kAv1CoefSkipCdfQ0,
      cdf.kAv1CoefSkipCdfQ1,
      cdf.kAv1CoefSkipCdfQ2,
      cdf.kAv1CoefSkipCdfQ3,
    ][qband];
    final eob16T = [
      cdf.kAv1EobBin16CdfQ0,
      cdf.kAv1EobBin16CdfQ1,
      cdf.kAv1EobBin16CdfQ2,
      cdf.kAv1EobBin16CdfQ3,
    ][qband];
    final eob64T = [
      cdf.kAv1EobBin64CdfQ0,
      cdf.kAv1EobBin64CdfQ1,
      cdf.kAv1EobBin64CdfQ2,
      cdf.kAv1EobBin64CdfQ3,
    ][qband];
    final eob32T = cdf.kAv1EobBin32CdfQ0; // rect only at qband 0
    final eob256T = cdf.kAv1EobBin256CdfQ0; // TX_16X16, qband 0 only
    final eob1024T = cdf.kAv1EobBin1024CdfQ0; // TX_32X32, qband 0 only
    final eobHiT = [
      cdf.kAv1EobHiBitCdfQ0,
      cdf.kAv1EobHiBitCdfQ1,
      cdf.kAv1EobHiBitCdfQ2,
      cdf.kAv1EobHiBitCdfQ3,
    ][qband];
    final baseTokT = [
      cdf.kAv1EobBaseTokCdfQ0,
      cdf.kAv1EobBaseTokCdfQ1,
      cdf.kAv1EobBaseTokCdfQ2,
      cdf.kAv1EobBaseTokCdfQ3,
    ][qband];
    final baseT = [
      cdf.kAv1CoeffBaseCdfQ0,
      cdf.kAv1CoeffBaseCdfQ1,
      cdf.kAv1CoeffBaseCdfQ2,
      cdf.kAv1CoeffBaseCdfQ3,
    ][qband];
    final brT = [
      cdf.kAv1CoeffBrCdfQ0,
      cdf.kAv1CoeffBrCdfQ1,
      cdf.kAv1CoeffBrCdfQ2,
      cdf.kAv1CoeffBrCdfQ3,
    ][qband];
    final dcSignT = [
      cdf.kAv1DcSignCdfQ0,
      cdf.kAv1DcSignCdfQ1,
      cdf.kAv1DcSignCdfQ2,
      cdf.kAv1DcSignCdfQ3,
    ][qband];
    final bhl = _bhlFor[txSize]!;
    final txShift = {0: 0, 1: 0, 2: 0, 3: 1, 4: 2, 5: 0, 6: 0}[txSize]!;
    final n = _nFor[txSize]!;
    final height = 1 << bhl;
    final width = n ~/ height;
    final bufLen = (height + 4) * (width + 4) + 16;
    // 2D -> default scan, VERT -> mrow, HORIZ -> mcol (TX_4X4).
    final scan2dT = {
      0: _scan4,
      1: _scan8,
      2: _scan16,
      3: _scan32,
      4: _scan32,
      5: _scan4x8,
      6: _scan8x4,
    }[txSize]!;
    final scan = class2d ? scan2dT : (txClass == 2 ? _mrow4 : _mcol4);
    // scan-index / position register widths: existing sizes keep 6 (byte-
    // identical). TX_16X16 (256 coeffs) needs 9-bit scan index + 8-bit position.
    final cidxW = n > 256 ? 11 : (n > 64 ? 9 : 6);
    final posW = n > 256 ? 10 : (n > 64 ? 8 : 6);
    // getTxsizeEntropyCtx: 0/1 for TX_4X4/8X8. TX_4X8/8X4 both give 1.
    final txsCtx = (txSize == 5 || txSize == 6) ? 1 : txSize;
    final txszGrp = txsCtx < 3 ? txsCtx : 3;
    final eobMultiCtx = class2d ? 0 : 1;
    final eobPtCdf = txSize == 0
        ? eob16T[pl * 2 + eobMultiCtx]
        : txSize == 2
        ? eob256T[pl * 2 + eobMultiCtx]
        : (txSize == 3 || txSize == 4)
        ? eob1024T[pl * 2 + eobMultiCtx]
        : ((txSize == 5 || txSize == 6)
              ? eob32T[pl * 2 + eobMultiCtx]
              : eob64T[pl * 2 + eobMultiCtx]);
    // readTxType needs both eob_pt contexts (2D + 1D) and the 7-sym ext-tx.
    final eobPtCdf1d = txSize == 0
        ? eob16T[pl * 2 + 1]
        : txSize == 2
        ? eob256T[pl * 2 + 1]
        : (txSize == 3 || txSize == 4)
        ? eob1024T[pl * 2 + 1]
        : ((txSize == 5 || txSize == 6)
              ? eob32T[pl * 2 + 1]
              : eob64T[pl * 2 + 1]);
    // ext-tx CDF row: indexed by squareTx (txsizeSqrMap). For square TX_8X8
    // squareTx=1 (_extTxCdf8). For TX_4X4 and the rect sizes (txsizeSqrMap=TX_4X4
    // -> squareTx=0) it is the TX_4X4 DC-mode row. The set/inverse-map is the
    // same DTT4_IDTX_1DDCT set (7 syms, _extTxInv) for all four sizes.
    final extTxCdf = txSize == 1 ? _extTxCdf8 : _extTxCdf4;
    final numCtx = readTxType ? 81 : 79;
    // kfIntra adds a 13-sym y_mode decode -> maxSyms >= 13.
    final maxSyms = kfIntra
        ? 13
        : (readTxType ? 7 : eobPtCdf.length); // 7-sym ext-tx forces >= 7
    final txbSkip = skipT[txsCtx * 13]; // txbSkipCtx 0 (plane-independent)
    final eobExtra = [
      for (var c = 0; c < 9; c++) eobHiT[txsCtx * 18 + pl * 9 + c],
    ];
    int paddedIdx(int pos) => pos + ((pos >> bhl) << 2);
    int rasterOf(int pos) => (pos & (height - 1)) * width + (pos >> bhl);
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('dc_q', PortDirection.input, width: 16); // dequant DC step
    createPort('ac_q', PortDirection.input, width: 16); // dequant AC step
    if (kfIntra) {
      createPort('skip_ctx', PortDirection.input, width: 2); // above+left skip
      createPort('above_ymode', PortDirection.input, width: 4);
      createPort('left_ymode', PortDirection.input, width: 4);
    }
    addOutput('done');
    addOutput('all_zero');
    addOutput('eob', width: 11);
    addOutput('levels_out', width: n * 8);
    addOutput('coeffs', width: n * 16); // dequantized, row-major, signed 16b
    addOutput('tx_type', width: 4); // decoded ext-tx type (readTxType)
    if (kfIntra) {
      addOutput('y_mode', width: 4);
      addOutput('block_skip');
      addOutput('angle_delta', width: 3); // raw 0..6 (= libaom delta + 3)
    }

    final clk = input('clk');
    final reset = input('reset');

    final ec = HarborOdEcDecoder(maxSyms: maxSyms, numCtx: numCtx, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

    final cc = HarborCoeffContext(txSize: txSize, name: 'cc');
    addSubModule(cc);

    // byte buffer + cursor
    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic idx) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        idx.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    // levels buffer (padded, fed to coeff_context)
    final levels = [
      for (var i = 0; i < bufLen; i++) Logic(name: 'lvl_$i', width: 8),
    ];

    // od_ec control (combinational from state)
    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    final ecCtx = Logic(name: 'ec_ctx', width: cw);
    final ecCdf = Logic(name: 'ec_cdf', width: maxSyms * 16);
    final ecNsyms = Logic(name: 'ec_nsyms', width: 5);
    ec.input('clk').srcConnection! <= clk;
    ec.input('reset').srcConnection! <= reset;
    ec.input('init').srcConnection! <= ecInit;
    ec.input('load').srcConnection! <= ecLoad;
    ec.input('decode').srcConnection! <= ecDecode;
    ec.input('ctx').srcConnection! <= ecCtx;
    ec.input('cdf').srcConnection! <= ecCdf;
    ec.input('num_syms').srcConnection! <= ecNsyms;
    ec.input('bytes_in').srcConnection! <=
        [
          byteAt(cursor),
          byteAt((cursor + Const(1, width: cursor.width))),
          byteAt((cursor + Const(2, width: cursor.width))),
        ].concat();
    final sym = ec.output('symbol');
    final bytePop = ec.output('byte_pop');

    Logic packCdf(List<int> icdf) => [
      for (var s = maxSyms - 1; s >= 0; s--)
        Const(s < icdf.length ? icdf[s] : 0, width: 16),
    ].concat();
    Logic romSel(List<int> table, Logic idx, int w) {
      Logic v = Const(table.last, width: w);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(
          idx.eq(Const(i, width: idx.width)),
          Const(table[i], width: w),
          v,
        );
      }
      return v;
    }

    // Select a packed CDF row from a runtime index over a build-time table.
    Logic selRow(List<List<int>> table, Logic idx) {
      Logic v = packCdf(table.last);
      for (var i = table.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), packCdf(table[i]), v);
      }
      return v;
    }

    // kfIntra y_mode neighbour context: _intraModeContext[above]*5 + [left].
    Logic yModeCtxIdx = Const(0, width: 5);
    if (kfIntra) {
      final aCtx = romSel(_intraModeContext, input('above_ymode'), 3);
      final lCtx = romSel(_intraModeContext, input('left_ymode'), 3);
      yModeCtxIdx =
          (aCtx.zeroExtend(5) * Const(5, width: 5) + lCtx.zeroExtend(5))
              .getRange(0, 5);
    }

    // preload schedule (real Q0 CDFs sliced for TX_4X4 / txsCtx0 / luma)
    final preload = <List<int>>[
      txbSkip, eobPtCdf, ...eobExtra, //
      for (var c = 0; c < 4; c++) baseTokT[txsCtx * 8 + pl * 4 + c],
      for (var c = 0; c < 41; c++) baseT[txsCtx * 82 + pl * 41 + c],
      for (var c = 0; c < 21; c++) brT[txszGrp * 42 + pl * 21 + c],
      _bypass,
      dcSignT[pl * 3], // dc_sign ctx 0
      if (readTxType) ...[extTxCdf, eobPtCdf1d], // ctx 79, 80
    ];
    assert(preload.length == numCtx, 'preload count');
    Logic selCdfByPl(Logic pl) {
      Logic v = packCdf(preload.last);
      for (var i = preload.length - 2; i >= 0; i--) {
        v = mux(pl.eq(Const(i, width: pl.width)), packCdf(preload[i]), v);
      }
      return v;
    }

    Logic selNsymsByPl(Logic pl) {
      Logic v = Const(preload.last.length, width: 5);
      for (var i = preload.length - 2; i >= 0; i--) {
        v = mux(
          pl.eq(Const(i, width: pl.width)),
          Const(preload[i].length, width: 5),
          v,
        );
      }
      return v;
    }

    // state + data
    const sIdle = 0, sPreload = 1, sInit = 2, sSkip = 3, sSkipCap = 4, sEobPt = 5, sEobPtCap = 6, sExtra = 7, sExtraCap = 8, sByp = 9, sBypDec = 10, sBypCap = 11, sBaseDec = 12, sBaseCap = 13, sBrDec = 14, sBrCap = 15, sNext = 16, sDone = 17,
    // phase B: signs + golomb + dequant + placement
    sPbCheck = 18, sPbSignLoad = 19, sPbSignDec = 20, sPbSignCap = 21, sPbGolChk = 22, sPbGolLeadLoad = 23, sPbGolLeadDec = 24, sPbGolLeadCap = 25, sPbGolReadLoad = 26, sPbGolReadDec = 27, sPbGolReadCap = 28, sPbDeq = 29, sPbNext = 30, sExtTxDec = 31, // readTxType: decode the ext-tx symbol
    sExtTxCap = 32, // readTxType: capture class / tx_type
    // kfIntra mode-info prefix (block_skip then y_mode) + ext-tx load.
    sBlkSkipLoad = 33, sBlkSkipDec = 34, sBlkSkipCap = 35, sYModeLoad = 36, sYModeDec = 37, sYModeCap = 38, sExtTxLoad = 39, sAngLoad = 40, // 8x8 directional: angle_delta
    sAngDec = 41, sAngCap = 42;
    final st = Logic(name: 'st', width: 6);
    final plReg = Logic(name: 'pl_r', width: 7);
    final allZeroReg = Logic(name: 'all_zero_r');
    final eobReg = Logic(name: 'eob_r', width: 11);
    final eobPtReg = Logic(name: 'eob_pt_r', width: 4);
    final eobExtraReg = Logic(name: 'eob_extra_r', width: 11);
    final offBitsReg = Logic(name: 'off_bits_r', width: 4);
    final bypIdxReg = Logic(name: 'byp_idx_r', width: 4);
    final cIdx = Logic(name: 'c_idx', width: cidxW); // scan index 0..n-1
    final levelReg = Logic(name: 'level_r', width: 8);
    final brIdxReg = Logic(name: 'br_idx_r', width: 3);
    // phase B registers
    final signReg = Logic(name: 'sign_r');
    final pbLevelReg = Logic(name: 'pb_level_r', width: 21);
    final golLeadReg = Logic(name: 'gol_lead_r', width: 6);
    final golXReg = Logic(name: 'gol_x_r', width: 21);
    final golCntReg = Logic(name: 'gol_cnt_r', width: 6);
    final coeffs = [
      for (var i = 0; i < n; i++) Logic(name: 'coef_$i', width: 16),
    ];
    // Decoded ext-tx class (0 2D / 1 HORIZ / 2 VERT) and tx_type (readTxType).
    final classReg = Logic(name: 'class_r', width: 2);
    final txTypeReg = Logic(name: 'txtype_r', width: 4);
    final yModeReg = Logic(name: 'ymode_r', width: 4);
    final blockSkipReg = Logic(name: 'blk_skip_r');
    final angleReg = Logic(
      name: 'angle_r',
      width: 3,
    ); // raw 0..6 (delta = -3..3)
    final isC0pb = cIdx.eq(Const(0, width: cidxW)); // pos == 0 (DC) in phase B
    // Runtime "2D class" predicate: from classReg when readTxType, else fixed.
    final class2dRt = readTxType
        ? classReg.eq(Const(0, width: 2))
        : Const(class2d ? 1 : 0);

    output('done') <= st.eq(Const(sDone, width: 6));
    output('all_zero') <= allZeroReg;
    output('eob') <= eobReg;
    output('tx_type') <= txTypeReg;
    if (kfIntra) {
      output('y_mode') <= yModeReg;
      output('block_skip') <= blockSkipReg;
      output('angle_delta') <= angleReg;
    }
    output('levels_out') <=
        [
          for (var pos = n - 1; pos >= 0; pos--) levels[paddedIdx(pos)],
        ].concat();
    output('coeffs') <= [for (var i = n - 1; i >= 0; i--) coeffs[i]].concat();

    // Dequantizer (combinational): drives the current phase-B coefficient.
    final deq = HarborDequant(bitDepth: 8, name: 'deq');
    addSubModule(deq);
    deq.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
    deq.input('dc_q').srcConnection! <= input('dc_q');
    deq.input('ac_q').srcConnection! <= input('ac_q');
    deq.input('is_dc').srcConnection! <= isC0pb;
    deq.input('sign').srcConnection! <= signReg;
    deq.input('shift').srcConnection! <=
        Const(txShift, width: 2); // av1_get_tx_scale
    final dqCoeff = deq.output('dq_coeff'); // 16-bit signed

    // pos = scan[cIdx]. Runtime 3-way scan select when readTxType (the class is
    // decoded), else the build-time scan.
    // 1D scans only exist for TX_4X4-class sizes (readTxType is off for >8x8),
    // so larger sizes fall back to the 2D scan (these are then unused).
    final scanVert =
        {0: _mrow4, 1: _mrow8, 5: _mrow4x8, 6: _mrow8x4}[txSize] ?? scan2dT;
    final scanHoriz =
        {0: _mcol4, 1: _mcol8, 5: _mcol4x8, 6: _mcol8x4}[txSize] ?? scan2dT;
    final scan2d = scan2dT;
    final posOfCidx = readTxType
        ? mux(
            classReg.eq(Const(2, width: 2)),
            romSel(scanVert, cIdx, posW), // VERT
            mux(
              classReg.eq(Const(1, width: 2)),
              romSel(scanHoriz, cIdx, posW),
              romSel(scan2d, cIdx, posW),
            ),
          ) // HORIZ : 2D
        : romSel(scan, cIdx, posW);
    final isEobMinus1 = cIdx.eq(
      (eobReg - Const(1, width: 11)).getRange(0, cidxW),
    );
    final isC0 = cIdx.eq(Const(0, width: cidxW));

    // Phase-B current level = levels[paddedIdx(pos)], pos = posOfCidx (the
    // runtime-decoded scan value). Indexing by the pos value (not the build-time
    // scan) makes the read correct under the runtime scan (readTxType).
    Logic pbLevelCur = levels[paddedIdx(n - 1)];
    for (var p = n - 2; p >= 0; p--) {
      pbLevelCur = mux(
        posOfCidx.eq(Const(p, width: posW)),
        levels[paddedIdx(p)],
        pbLevelCur,
      );
    }

    // coeff_context drive (width-match each port).
    final ccIdxW = cc.input('coeff_idx').width;
    cc.input('coeff_idx').srcConnection! <=
        (ccIdxW <= posW
            ? posOfCidx.getRange(0, ccIdxW)
            : posOfCidx.zeroExtend(ccIdxW));
    final scanIdxW = cc.input('scan_idx').width;
    cc.input('scan_idx').srcConnection! <=
        (scanIdxW <= cidxW
            ? cIdx.getRange(0, scanIdxW)
            : cIdx.zeroExtend(scanIdxW));
    cc.input('tx_class').srcConnection! <=
        (readTxType ? classReg : Const(txClass, width: 2));
    cc.input('levels').srcConnection! <=
        [for (var i = bufLen - 1; i >= 0; i--) levels[i]].concat();
    final baseEobCtx = cc.output('base_eob_ctx'); // 0..3
    final base2dCtx = cc.output('base_ctx_2d'); // 0..25
    final baseGenCtx = cc.output('base_ctx_gen'); // 0..40
    final brEobCtx = cc.output('br_ctx_eob'); // 0/7/14
    final br2dCtx = cc.output('br_ctx_2d'); // 0..20
    final brGenCtx = cc.output('br_ctx_gen'); // 0..20

    // Base/br context routing. For TX_CLASS_2D the eob-1 coeff uses base_eob,
    // position 0 uses the general context, and the middle positions use the 2D
    // fast-path context. For HORIZ/VERT every non-eob-1 position uses the
    // general (class-aware) context (libaom's read_coeffs_reverse).
    Logic baseEobFlat() =>
        (Const(_ctxBaseEob0, width: cw) + baseEobCtx.zeroExtend(cw)).getRange(
          0,
          cw,
        );
    Logic baseFlatFor(Logic ctx) =>
        (Const(_ctxBase0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
    // 2D middle = base2d, else general. Non-2D = always general. When the class
    // is runtime (readTxType) the choice is a mux on class2dRt.
    final base2dPath = mux(
      isC0,
      baseFlatFor(baseGenCtx),
      baseFlatFor(base2dCtx),
    );
    final nonEob1Base = readTxType
        ? mux(class2dRt, base2dPath, baseFlatFor(baseGenCtx))
        : (class2d ? base2dPath : baseFlatFor(baseGenCtx));
    final baseFlat = mux(isEobMinus1, baseEobFlat(), nonEob1Base);
    final baseNsyms = mux<Logic>(
      isEobMinus1,
      Const(3, width: 5),
      Const(4, width: 5),
    );
    // Flat od_ec ctx for the current br decode.
    final br2dPath = mux(isC0, brGenCtx.zeroExtend(cw), br2dCtx.zeroExtend(cw));
    final nonEob1Br = readTxType
        ? mux(class2dRt, br2dPath, brGenCtx.zeroExtend(cw))
        : (class2d ? br2dPath : brGenCtx.zeroExtend(cw));
    final brSubCtx = mux(isEobMinus1, brEobCtx.zeroExtend(cw), nonEob1Br);
    final brFlat = (Const(_ctxBr0, width: cw) + brSubCtx).getRange(0, cw);

    final eobCtx = (eobPtReg - Const(3, width: 4)).getRange(0, 4);
    final offBits = romSel(_eobOffsetBits, eobPtReg, 4);
    final groupStart = romSel(_eobGroupStart, eobPtReg, 11);

    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: 6), [
          ecLoad < Const(1),
          ecCtx < plReg.getRange(0, cw),
          ecCdf < selCdfByPl(plReg),
          ecNsyms < selNsymsByPl(plReg),
        ]),
        CaseItem(Const(sInit, width: 6), [ecInit < Const(1)]),
        CaseItem(Const(sSkip, width: 6), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxSkip, width: cw),
        ]),
        CaseItem(Const(sExtTxDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxExtTx, width: cw),
        ]),
        // kfIntra mode-info prefix: block_skip then y_mode (scratch ctx 79),
        // then the y_mode-indexed ext-tx CDF reloaded into ctx 79.
        if (kfIntra) ...[
          CaseItem(Const(sBlkSkipLoad, width: 6), [
            ecLoad < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
            ecCdf < selRow(_skipCdf, input('skip_ctx')),
            ecNsyms < Const(2, width: 5),
          ]),
          CaseItem(Const(sBlkSkipDec, width: 6), [
            ecDecode < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
          ]),
          CaseItem(Const(sYModeLoad, width: 6), [
            ecLoad < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
            ecCdf < selRow(cdf.kAv1DefaultKfYModeCdf, yModeCtxIdx),
            ecNsyms < Const(13, width: 5),
          ]),
          CaseItem(Const(sYModeDec, width: 6), [
            ecDecode < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
          ]),
          CaseItem(Const(sExtTxLoad, width: 6), [
            ecLoad < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
            ecCdf <
                selRow(txSize == 0 ? _extTxByMode : _extTxByMode8, yModeReg),
            ecNsyms < Const(7, width: 5),
          ]),
          // 8x8 directional: angle_delta CDF by (y_mode - V_PRED).
          CaseItem(Const(sAngLoad, width: 6), [
            ecLoad < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
            ecCdf <
                selRow(
                  _angleCdf,
                  (yModeReg - Const(1, width: 4)).getRange(0, 4),
                ),
            ecNsyms < Const(7, width: 5),
          ]),
          CaseItem(Const(sAngDec, width: 6), [
            ecDecode < Const(1),
            ecCtx < Const(_ctxExtTx, width: cw),
          ]),
        ],
        CaseItem(Const(sEobPt, width: 6), [
          ecDecode < Const(1),
          // 2D class uses eob_pt ctx 1, the 1D classes use ctx 80 (readTxType).
          ecCtx <
              (readTxType
                  ? mux<Logic>(
                      class2dRt,
                      Const(_ctxEobPt, width: cw),
                      Const(_ctxEobPt1d, width: cw),
                    )
                  : Const(_ctxEobPt, width: cw)),
        ]),
        CaseItem(Const(sExtra, width: 6), [
          If(
            offBits.gt(Const(0, width: 4)),
            then: [
              ecDecode < Const(1),
              ecCtx <
                  (Const(_ctxEobExtra0, width: cw) + eobCtx.zeroExtend(cw))
                      .getRange(0, cw),
            ],
          ),
        ]),
        CaseItem(Const(sByp, width: 6), [
          If(
            bypIdxReg.lt(offBitsReg),
            then: [
              ecLoad < Const(1),
              ecCtx < Const(_ctxBypass, width: cw),
              ecCdf < packCdf(_bypass),
              ecNsyms < Const(2, width: 5),
            ],
          ),
        ]),
        CaseItem(Const(sBypDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
        ]),
        CaseItem(Const(sBaseDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < baseFlat,
          ecNsyms < baseNsyms,
        ]),
        CaseItem(Const(sBrDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < brFlat,
          ecNsyms < Const(4, width: 5),
        ]),
        // phase B: sign (dc_sign adaptive for the DC coeff, else a bypass bit)
        CaseItem(Const(sPbSignLoad, width: 6), [
          ecLoad < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
          ecCdf < packCdf(_bypass),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(sPbSignDec, width: 6), [
          ecDecode < Const(1),
          ecCtx <
              mux<Logic>(
                isC0pb,
                Const(_ctxDcSign, width: cw),
                Const(_ctxBypass, width: cw),
              ),
        ]),
        // phase B: golomb (exp-Golomb over bypass bits)
        CaseItem(Const(sPbGolLeadLoad, width: 6), [
          ecLoad < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
          ecCdf < packCdf(_bypass),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(sPbGolLeadDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
        ]),
        CaseItem(Const(sPbGolReadLoad, width: 6), [
          ecLoad < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
          ecCdf < packCdf(_bypass),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(sPbGolReadDec, width: 6), [
          ecDecode < Const(1),
          ecCtx < Const(_ctxBypass, width: cw),
        ]),
      ]),
    ]);

    Logic cap8(Logic v) => v.getRange(0, 8); // level fits 8 bits (<= 15)

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 6),
          cursor < Const(0, width: cursor.width),
          plReg < Const(0, width: 7),
          allZeroReg < Const(0),
          eobReg < Const(0, width: 11),
          eobPtReg < Const(0, width: 4),
          eobExtraReg < Const(0, width: 11),
          offBitsReg < Const(0, width: 4),
          bypIdxReg < Const(0, width: 4),
          cIdx < Const(0, width: cidxW),
          levelReg < Const(0, width: 8),
          brIdxReg < Const(0, width: 3),
          signReg < Const(0),
          pbLevelReg < Const(0, width: 21),
          golLeadReg < Const(0, width: 6),
          golXReg < Const(0, width: 21),
          golCntReg < Const(0, width: 6),
          classReg < Const(0, width: 2),
          txTypeReg < Const(0, width: 4),
          yModeReg < Const(0, width: 4),
          blockSkipReg < Const(0),
          angleReg < Const(0, width: 3),
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
          for (var i = 0; i < bufLen; i++) levels[i] < Const(0, width: 8),
          for (var i = 0; i < n; i++) coeffs[i] < Const(0, width: 16),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 6), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  for (var i = 0; i < bufLen; i++)
                    levels[i] < Const(0, width: 8),
                  for (var i = 0; i < n; i++) coeffs[i] < Const(0, width: 16),
                  cursor < Const(0, width: cursor.width),
                  plReg < Const(0, width: 7),
                  st < Const(sPreload, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: 6), [
              If(
                plReg.eq(Const(numCtx - 1, width: 7)),
                then: [st < Const(sInit, width: 6)],
                orElse: [plReg < (plReg + Const(1, width: 7))],
              ),
            ]),
            CaseItem(Const(sInit, width: 6), [
              st < Const(kfIntra ? sBlkSkipLoad : sSkip, width: 6),
            ]),
            CaseItem(Const(sSkip, width: 6), [st < Const(sSkipCap, width: 6)]),
            CaseItem(Const(sSkipCap, width: 6), [
              allZeroReg < sym[0],
              If(
                sym[0],
                then: [
                  eobReg < Const(0, width: 11),
                  st < Const(sDone, width: 6),
                ],
                orElse: [
                  // kfIntra loads the y_mode-indexed ext-tx CDF first. Plain
                  // readTxType decodes the fixed ext-tx CDF directly.
                  st <
                      Const(
                        kfIntra
                            ? sExtTxLoad
                            : (readTxType ? sExtTxDec : sEobPt),
                        width: 6,
                      ),
                ],
              ),
            ]),
            // kfIntra mode-info prefix: block_skip, then y_mode (always read),
            // then start the coeff path (txb_skip). When block_skip is set there
            // is no residual: eob = 0, coeffs stay zero.
            if (kfIntra) ...[
              CaseItem(Const(sBlkSkipLoad, width: 6), [
                st < Const(sBlkSkipDec, width: 6),
              ]),
              CaseItem(Const(sBlkSkipDec, width: 6), [
                st < Const(sBlkSkipCap, width: 6),
              ]),
              CaseItem(Const(sBlkSkipCap, width: 6), [
                blockSkipReg < sym[0],
                st < Const(sYModeLoad, width: 6),
              ]),
              CaseItem(Const(sYModeLoad, width: 6), [
                st < Const(sYModeDec, width: 6),
              ]),
              CaseItem(Const(sYModeDec, width: 6), [
                st < Const(sYModeCap, width: 6),
              ]),
              CaseItem(Const(sYModeCap, width: 6), [
                yModeReg < sym.zeroExtend(4),
                angleReg < Const(0, width: 3),
                // angle_delta is read after y_mode regardless of skip (8x8 dir).
                if (txSize == 1)
                  If(
                    sym.getRange(0, 4).gte(Const(1, width: 4)) &
                        sym.getRange(0, 4).lte(Const(8, width: 4)),
                    then: [st < Const(sAngLoad, width: 6)],
                    orElse: [
                      If(
                        blockSkipReg,
                        then: [
                          eobReg < Const(0, width: 11),
                          allZeroReg < Const(1),
                          st < Const(sDone, width: 6),
                        ],
                        orElse: [st < Const(sSkip, width: 6)],
                      ),
                    ],
                  )
                else
                  If(
                    blockSkipReg,
                    then: [
                      eobReg < Const(0, width: 11),
                      allZeroReg < Const(1),
                      st < Const(sDone, width: 6),
                    ],
                    orElse: [st < Const(sSkip, width: 6)],
                  ),
              ]),
              CaseItem(Const(sAngLoad, width: 6), [
                st < Const(sAngDec, width: 6),
              ]),
              CaseItem(Const(sAngDec, width: 6), [
                st < Const(sAngCap, width: 6),
              ]),
              CaseItem(Const(sAngCap, width: 6), [
                angleReg < sym.getRange(0, 3),
                If(
                  blockSkipReg,
                  then: [
                    eobReg < Const(0, width: 11),
                    allZeroReg < Const(1),
                    st < Const(sDone, width: 6),
                  ],
                  orElse: [st < Const(sSkip, width: 6)],
                ),
              ]),
              CaseItem(Const(sExtTxLoad, width: 6), [
                st < Const(sExtTxDec, width: 6),
              ]),
            ],
            // ext-tx read (readTxType): decode the symbol, derive class/tx_type.
            CaseItem(Const(sExtTxDec, width: 6), [
              st < Const(sExtTxCap, width: 6),
            ]),
            CaseItem(Const(sExtTxCap, width: 6), [
              classReg <
                  mux(
                    sym.eq(Const(2, width: ec.symWidth)),
                    Const(2, width: 2),
                    mux<Logic>(
                      sym.eq(Const(3, width: ec.symWidth)),
                      Const(1, width: 2),
                      Const(0, width: 2),
                    ),
                  ),
              txTypeReg <
                  () {
                    Logic v = Const(_extTxInv.last, width: 4);
                    for (var i = _extTxInv.length - 2; i >= 0; i--) {
                      v = mux(
                        sym.eq(Const(i, width: ec.symWidth)),
                        Const(_extTxInv[i], width: 4),
                        v,
                      );
                    }
                    return v;
                  }(),
              st < Const(sEobPt, width: 6),
            ]),
            CaseItem(Const(sEobPt, width: 6), [
              st < Const(sEobPtCap, width: 6),
            ]),
            CaseItem(Const(sEobPtCap, width: 6), [
              eobPtReg <
                  (sym.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
              st < Const(sExtra, width: 6),
            ]),
            CaseItem(Const(sExtra, width: 6), [
              offBitsReg < offBits,
              eobExtraReg < Const(0, width: 11),
              If(
                offBits.eq(Const(0, width: 4)),
                then: [st < Const(sByp, width: 6)],
                orElse: [st < Const(sExtraCap, width: 6)],
              ),
            ]),
            CaseItem(Const(sExtraCap, width: 6), [
              If(
                sym[0],
                then: [
                  eobExtraReg <
                      (Const(1, width: 11) <<
                              (offBitsReg - Const(1, width: 4)).getRange(0, 4))
                          .getRange(0, 11),
                ],
              ),
              bypIdxReg < Const(1, width: 4),
              st < Const(sByp, width: 6),
            ]),
            CaseItem(Const(sByp, width: 6), [
              If(
                bypIdxReg.gte(offBitsReg),
                then: [
                  // eob settled. Start the base reverse-scan at cIdx = eob-1.
                  eobReg <
                      mux(
                        groupStart.gt(Const(2, width: 11)),
                        (groupStart + eobExtraReg).getRange(0, 11),
                        groupStart,
                      ),
                  cIdx <
                      (mux(
                                groupStart.gt(Const(2, width: 11)),
                                (groupStart + eobExtraReg).getRange(0, 11),
                                groupStart,
                              ) -
                              Const(1, width: 11))
                          .getRange(0, cidxW),
                  st < Const(sBaseDec, width: 6),
                ],
                orElse: [st < Const(sBypDec, width: 6)],
              ),
            ]),
            CaseItem(Const(sBypDec, width: 6), [st < Const(sBypCap, width: 6)]),
            CaseItem(Const(sBypCap, width: 6), [
              If(
                sym[0],
                then: [
                  eobExtraReg <
                      (eobExtraReg |
                              (Const(1, width: 11) <<
                                      (offBitsReg -
                                              Const(1, width: 4) -
                                              bypIdxReg)
                                          .getRange(0, 4))
                                  .getRange(0, 11))
                          .getRange(0, 11),
                ],
              ),
              bypIdxReg < (bypIdxReg + Const(1, width: 4)),
              st < Const(sByp, width: 6),
            ]),
            // base reverse-scan
            CaseItem(Const(sBaseDec, width: 6), [
              st < Const(sBaseCap, width: 6),
            ]),
            CaseItem(Const(sBaseCap, width: 6), [
              // level = (eob-1 ? sym+1 : sym).
              levelReg <
                  mux(
                    isEobMinus1,
                    (sym.zeroExtend(8) + Const(1, width: 8)).getRange(0, 8),
                    sym.zeroExtend(8),
                  ),
              If(
                mux(
                  isEobMinus1,
                  sym.zeroExtend(8) + Const(1, width: 8),
                  sym.zeroExtend(8),
                ).gt(Const(2, width: 8)),
                then: [
                  brIdxReg < Const(0, width: 3),
                  st < Const(sBrDec, width: 6),
                ],
                orElse: [
                  // write level at the runtime position posOfCidx, advance.
                  for (var p = 0; p < n; p++)
                    If(
                      posOfCidx.eq(Const(p, width: posW)),
                      then: [
                        levels[paddedIdx(p)] <
                            cap8(
                              mux(
                                isEobMinus1,
                                sym.zeroExtend(8) + Const(1, width: 8),
                                sym.zeroExtend(8),
                              ),
                            ),
                      ],
                    ),
                  st < Const(sNext, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sBrDec, width: 6), [st < Const(sBrCap, width: 6)]),
            CaseItem(Const(sBrCap, width: 6), [
              // level += k, break when k < 3 or after 4 reads.
              levelReg < (levelReg + sym.zeroExtend(8)).getRange(0, 8),
              If(
                sym.lt(Const(3, width: ec.symWidth)) |
                    brIdxReg.eq(Const(3, width: 3)),
                then: [
                  for (var p = 0; p < n; p++)
                    If(
                      posOfCidx.eq(Const(p, width: posW)),
                      then: [
                        levels[paddedIdx(p)] <
                            cap8((levelReg + sym.zeroExtend(8)).getRange(0, 8)),
                      ],
                    ),
                  st < Const(sNext, width: 6),
                ],
                orElse: [
                  brIdxReg < (brIdxReg + Const(1, width: 3)),
                  st < Const(sBrDec, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sNext, width: 6), [
              If(
                cIdx.eq(Const(0, width: cidxW)),
                then: [
                  // base levels done. Start phase B (signs/golomb/dequant)
                  // forward from cIdx = 0.
                  cIdx < Const(0, width: cidxW),
                  st < Const(sPbCheck, width: 6),
                ],
                orElse: [
                  cIdx < (cIdx - Const(1, width: cidxW)),
                  st < Const(sBaseDec, width: 6),
                ],
              ),
            ]),
            // phase B
            CaseItem(Const(sPbCheck, width: 6), [
              pbLevelReg < pbLevelCur.zeroExtend(21),
              If(
                pbLevelCur.eq(Const(0, width: 8)),
                then: [
                  st <
                      Const(
                        sPbNext,
                        width: 6,
                      ), // zero coeff: leave coeffs[.] = 0
                ],
                orElse: [
                  If(
                    isC0pb,
                    then: [st < Const(sPbSignDec, width: 6)], // DC: dc_sign ctx
                    orElse: [st < Const(sPbSignLoad, width: 6)],
                  ), // AC: bypass
                ],
              ),
            ]),
            CaseItem(Const(sPbSignLoad, width: 6), [
              st < Const(sPbSignDec, width: 6),
            ]),
            CaseItem(Const(sPbSignDec, width: 6), [
              st < Const(sPbSignCap, width: 6),
            ]),
            CaseItem(Const(sPbSignCap, width: 6), [
              signReg < sym[0],
              st < Const(sPbGolChk, width: 6),
            ]),
            CaseItem(Const(sPbGolChk, width: 6), [
              If(
                pbLevelReg.gte(Const(15, width: 21)),
                then: [
                  golLeadReg < Const(0, width: 6),
                  st < Const(sPbGolLeadLoad, width: 6),
                ],
                orElse: [st < Const(sPbDeq, width: 6)],
              ),
            ]),
            CaseItem(Const(sPbGolLeadLoad, width: 6), [
              st < Const(sPbGolLeadDec, width: 6),
            ]),
            CaseItem(Const(sPbGolLeadDec, width: 6), [
              st < Const(sPbGolLeadCap, width: 6),
            ]),
            CaseItem(Const(sPbGolLeadCap, width: 6), [
              If(
                sym[0] | golLeadReg.gte(Const(31, width: 6)),
                then: [
                  // terminator (1 bit) found. Read golLeadReg value bits next.
                  golXReg < Const(1, width: 21),
                  golCntReg < Const(0, width: 6),
                  If(
                    golLeadReg.eq(Const(0, width: 6)),
                    then: [
                      st < Const(sPbDeq, width: 6),
                    ], // value = 0, level += 0
                    orElse: [st < Const(sPbGolReadLoad, width: 6)],
                  ),
                ],
                orElse: [
                  golLeadReg < (golLeadReg + Const(1, width: 6)),
                  st < Const(sPbGolLeadLoad, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sPbGolReadLoad, width: 6), [
              st < Const(sPbGolReadDec, width: 6),
            ]),
            CaseItem(Const(sPbGolReadDec, width: 6), [
              st < Const(sPbGolReadCap, width: 6),
            ]),
            CaseItem(Const(sPbGolReadCap, width: 6), [
              // x = (x << 1) | bit, after golLeadReg bits, level += (x - 1).
              If(
                (golCntReg + Const(1, width: 6)).eq(golLeadReg),
                then: [
                  pbLevelReg <
                      (pbLevelReg +
                              ((golXReg << 1) | sym[0].zeroExtend(21)) -
                              Const(1, width: 21))
                          .getRange(0, 21),
                  st < Const(sPbDeq, width: 6),
                ],
                orElse: [
                  golXReg <
                      ((golXReg << 1) | sym[0].zeroExtend(21)).getRange(0, 21),
                  golCntReg < (golCntReg + Const(1, width: 6)),
                  st < Const(sPbGolReadLoad, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sPbDeq, width: 6), [
              // place the dequantized coeff at its raster position (runtime pos).
              for (var p = 0; p < n; p++)
                If(
                  posOfCidx.eq(Const(p, width: posW)),
                  then: [coeffs[rasterOf(p)] < dqCoeff],
                ),
              st < Const(sPbNext, width: 6),
            ]),
            CaseItem(Const(sPbNext, width: 6), [
              If(
                cIdx.eq((eobReg - Const(1, width: 11)).getRange(0, cidxW)),
                then: [st < Const(sDone, width: 6)],
                orElse: [
                  cIdx < (cIdx + Const(1, width: cidxW)),
                  st < Const(sPbCheck, width: 6),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 6), [
              If(~input('start'), then: [st < Const(sIdle, width: 6)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
