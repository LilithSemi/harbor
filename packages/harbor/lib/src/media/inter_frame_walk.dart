import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'coeff_context.dart';
import 'global_mv.dart';
import 'mv_projection.dart';
import 'od_ec_decoder.dart';

/// Harbor AV1 INTER-frame mode-info entropy decoder (Phase 3 generalization).
///
/// Decodes a real single-ref inter frame's mode info bit-exact per the AV1
/// spec: the partition recursion over one 64x64
/// superblock (10 shapes), per-mi neighbour grids, the full spatial
/// find_mv_refs (8-entry sorted dedup ref-mv stack, scan row/col/blk,
/// add_ref_mv_candidate, sort_stack, mode_context, single-ref extra
/// candidates, clamp), all single-ref inter modes (NEAREST/NEAR/GLOBAL/NEW),
/// DRL, and read_mv, driving the shared od_ec range coder.
///
/// Scope (a 4-quadrant clean-translation 64x64 cq50 frame): single-ref,
/// referenceMode SINGLE, useRefFrameMvs=false (no temporal MVs), global motion
/// IDENTITY (GLOBALMV->0,0, no global-mv-block substitution), all blocks skip
/// (no residual), txMode LARGEST (no tx_size symbol), motion_mode /interp not
/// switchable, skip_mode not present, segmentation off. One tile == one 64x64
/// SB. The frame fits exactly (miRows==miCols==16) so partitions never hit a
/// frame edge (hasRows/hasCols always true).
class HarborInterFrameWalk extends BridgeModule {
  final int maxBytes;

  /// The set of luma coefficient tx sizes to instantiate context engines for
  /// (libaom TX_SIZE). Square TX_4X4/8X8/16X16 (0/1/2) plus optionally the small
  /// rectangular sizes TX_4X8/8X4/8X16/16X8/4X16/16X4 (5/6/7/8/13/14). The
  /// generic geometry supports every listed size. Instantiating only the sizes a
  /// stream actually uses keeps the ROHD simulation tractable (each engine is
  /// re-evaluated on every level-buffer write). Real silicon lists all of them.
  final List<int> txCoeffSizes;

  /// When true, wire the TMVP (temporal motion vector prediction) path into
  /// find_mv_refs: the projected motion field (`tpl_*` input grids, produced by
  /// [HarborMotionField]) is sampled and temporal candidates are added to the
  /// ref-mv stack (SW `_addTemporalMvs`). Adds the `use_ref_frame_mvs`, `tpl_*`
  /// and `cur_off` input ports. When false the module is byte-identical to the
  /// spatial-only decoder (no extra ports, temporal phase never elaborated).
  final bool enableTmvp;

  /// When true, wire the frame-level global-motion models (`gm_type` + `gm_mat`
  /// input ports) into the GLOBALMV / GLOBAL_GLOBALMV mode MV, the ref-mv-stack
  /// global candidates, the temporal globalmv mode-context trigger, and the
  /// non-translational-global motion_mode suppression (SW gm_get_motion_vector /
  /// _motionModeAllowed). When false the module is byte-identical to the
  /// identity-global-motion decoder (GLOBALMV -> (0,0), no extra ports).
  final bool enableGlobalMotion;

  static const _miWide = [
    1, 1, 2, 2, 2, 4, 4, 4, 8, 8, 8, 16, 16, 16, 32, 32, 1, 4, 2, 8, 4, 16, //
  ];
  static const _miHigh = [
    1, 2, 1, 2, 4, 2, 4, 8, 4, 8, 16, 8, 16, 32, 16, 32, 4, 1, 8, 2, 16, 4, //
  ];
  static const _miWideLog2 = [
    0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 0, 2, 1, 3, 2, 4, //
  ];
  // block_size_wide / block_size_high in PIXELS (mi_size * 4), for the global-mv
  // warp-centre evaluation (gm_get_motion_vector).
  static const _bsWide = [
    4,
    4,
    8,
    8,
    8,
    16,
    16,
    16,
    32,
    32,
    32,
    64,
    64,
    64,
    128,
    128,
    4,
    16,
    8,
    32, //
    16, 64,
  ];
  static const _bsHigh = [
    4,
    8,
    4,
    8,
    16,
    8,
    16,
    32,
    16,
    32,
    64,
    32,
    64,
    128,
    64,
    128,
    16,
    4,
    32,
    8, //
    64, 16,
  ];
  static const _partCtxAbove = [
    31, 31, 30, 30, 30, 28, 28, 28, 24, 24, 24, 16, 16, 16, 0, 0, 31, 28, 30, //
    24, 28, 16,
  ];
  static const _partCtxLeft = [
    31, 30, 31, 30, 28, 30, 28, 24, 28, 24, 16, 24, 16, 0, 16, 0, 28, 31, 24, //
    30, 16, 28,
  ];
  // default_scan_16x16 (TX_16X16, 2D class). VERT/HORIZ classes use the mrow /
  // mcol formulas (see the residual FSM), so only the 2D scan needs a ROM.
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
  // default_scan_32x32 (TX_32X32, 2D class, column-major raster position by scan
  // index). 32x32 inter uses only DCT_DCT/IDTX (both 2D), so no 1D scan needed.
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
  // ext_tx inverse map for setType=4 (inter TX_16X16, EXT_TX_SET_DTT9_IDTX_1DDCT,
  // 12-sym) and setType=5 (EXT_TX_SET_ALL16, 16-sym, TX_4X4/TX_8X8/rect inter):
  // symbol -> tx_type. txClass derives from the resulting TX_TYPE via _txClass16.
  // av1_ext_tx_inv[EXT_TX_SET_DCT_IDTX] (2-sym, inter TX_32X32): sym0->IDTX(9),
  // sym1->DCT_DCT(0). Both resolve to TX_CLASS_2D via _txClass16.
  static const _extTxInv1 = [9, 0];
  static const _extTxInv4 = [9, 10, 11, 0, 1, 2, 4, 5, 3, 6, 7, 8, 0, 0, 0, 0];
  static const _extTxInv5 = [
    9, 10, 11, 12, 13, 14, 15, 0, 1, 2, 4, 5, 3, 6, 7, 8, //
  ];
  // get_tx_class(tx_type): 2D(0) for 0..9, VERT(2) for V_* (10,12,14),
  // HORIZ(1) for H_* (11,13,15). Indexed by TX_TYPE (not the ext-tx symbol).
  static const _txClass16 = [
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 1, 2, 1, 2, 1, //
  ];
  // 2D default scans (column-major raster position by scan index).
  static const _scan4 = [0, 4, 1, 2, 5, 8, 12, 9, 6, 3, 7, 10, 13, 14, 11, 15];
  static const _scan8 = [
    0, 8, 1, 2, 9, 16, 24, 17, 10, 3, 4, 11, 18, 25, 32, 40, //
    33, 26, 19, 12, 5, 6, 13, 20, 27, 34, 41, 48, 56, 49, 42, 35, //
    28, 21, 14, 7, 15, 22, 29, 36, 43, 50, 57, 58, 51, 44, 37, 30, //
    23, 31, 38, 45, 52, 59, 60, 53, 46, 39, 47, 54, 61, 62, 55, 63,
  ];
  // 2D default scans for the small rectangular tx sizes (column-major raster
  // position by scan index). VERT/HORIZ classes use the mrow/mcol formulas.
  static const _scan4x8 = [
    0, 8, 1, 16, 9, 2, 24, 17, 10, 3, 25, 18, 11, 4, 26, 19, 12, 5, 27, 20, //
    13, 6, 28, 21, 14, 7, 29, 22, 15, 30, 23, 31,
  ];
  static const _scan8x4 = [
    0, 1, 4, 2, 5, 8, 3, 6, 9, 12, 7, 10, 13, 16, 11, 14, 17, 20, 15, 18, 21, //
    24, 19, 22, 25, 28, 23, 26, 29, 27, 30, 31,
  ];
  static const _scan4x16 = [
    0, 16, 1, 32, 17, 2, 48, 33, 18, 3, 49, 34, 19, 4, 50, 35, 20, 5, 51, 36, //
    21, 6, 52, 37, 22, 7, 53, 38, 23, 8, 54, 39, 24, 9, 55, 40, 25, 10, 56, //
    41, 26, 11, 57, 42, 27, 12, 58, 43, 28, 13, 59, 44, 29, 14, 60, 45, 30, //
    15, 61, 46, 31, 62, 47, 63,
  ];
  static const _scan16x4 = [
    0, 1, 4, 2, 5, 8, 3, 6, 9, 12, 7, 10, 13, 16, 11, 14, 17, 20, 15, 18, 21, //
    24, 19, 22, 25, 28, 23, 26, 29, 32, 27, 30, 33, 36, 31, 34, 37, 40, 35, //
    38, 41, 44, 39, 42, 45, 48, 43, 46, 49, 52, 47, 50, 53, 56, 51, 54, 57, //
    60, 55, 58, 61, 59, 62, 63,
  ];
  static const _scan8x16 = [
    0,
    16,
    1,
    32,
    17,
    2,
    48,
    33,
    18,
    3,
    64,
    49,
    34,
    19,
    4,
    80,
    65,
    50,
    35,
    20, //
    5,
    96,
    81,
    66,
    51,
    36,
    21,
    6,
    112,
    97,
    82,
    67,
    52,
    37,
    22,
    7,
    113,
    98,
    83, //
    68, 53, 38, 23, 8, 114, 99, 84, 69, 54, 39, 24, 9, 115, 100, 85, 70, 55, //
    40, 25, 10, 116, 101, 86, 71, 56, 41, 26, 11, 117, 102, 87, 72, 57, 42, //
    27, 12, 118, 103, 88, 73, 58, 43, 28, 13, 119, 104, 89, 74, 59, 44, 29, //
    14, 120, 105, 90, 75, 60, 45, 30, 15, 121, 106, 91, 76, 61, 46, 31, 122, //
    107, 92, 77, 62, 47, 123, 108, 93, 78, 63, 124, 109, 94, 79, 125, 110, //
    95, 126, 111, 127,
  ];
  static const _scan16x8 = [
    0, 1, 8, 2, 9, 16, 3, 10, 17, 24, 4, 11, 18, 25, 32, 5, 12, 19, 26, 33, //
    40, 6, 13, 20, 27, 34, 41, 48, 7, 14, 21, 28, 35, 42, 49, 56, 15, 22, 29, //
    36, 43, 50, 57, 64, 23, 30, 37, 44, 51, 58, 65, 72, 31, 38, 45, 52, 59, //
    66, 73, 80, 39, 46, 53, 60, 67, 74, 81, 88, 47, 54, 61, 68, 75, 82, 89, //
    96, 55, 62, 69, 76, 83, 90, 97, 104, 63, 70, 77, 84, 91, 98, 105, 112, //
    71, 78, 85, 92, 99, 106, 113, 120, 79, 86, 93, 100, 107, 114, 121, 87, //
    94, 101, 108, 115, 122, 95, 102, 109, 116, 123, 103, 110, 117, 124, 111, //
    118, 125, 119, 126, 127,
  ];
  // 2D default scans for the tall rectangular tx sizes TX_16X32 (9) /
  // TX_8X32 (15) (column-major raster position by scan index). Copied from
  // the SW oracle av1_scan_orders (default_scan_16x32 / default_scan_8x32).
  // These sizes' inter ext-tx set is DCT_IDTX (both 2D), so no 1D scan.
  static const _scan16x32 = [
    0, 32, 1, 64, 33, 2, 96, 65, 34, 3, 128, 97, 66, 35, 4, 160, //
    129, 98, 67, 36, 5, 192, 161, 130, 99, 68, 37, 6, 224, 193, 162, 131, //
    100, 69, 38, 7, 256, 225, 194, 163, 132, 101, 70, 39, 8, 288, 257, 226, //
    195,
    164,
    133,
    102,
    71,
    40,
    9,
    320,
    289,
    258,
    227,
    196,
    165,
    134,
    103,
    72, //
    41,
    10,
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
    384,
    353, //
    322,
    291,
    260,
    229,
    198,
    167,
    136,
    105,
    74,
    43,
    12,
    416,
    385,
    354,
    323,
    292, //
    261,
    230,
    199,
    168,
    137,
    106,
    75,
    44,
    13,
    448,
    417,
    386,
    355,
    324,
    293,
    262, //
    231,
    200,
    169,
    138,
    107,
    76,
    45,
    14,
    480,
    449,
    418,
    387,
    356,
    325,
    294,
    263, //
    232,
    201,
    170,
    139,
    108,
    77,
    46,
    15,
    481,
    450,
    419,
    388,
    357,
    326,
    295,
    264, //
    233,
    202,
    171,
    140,
    109,
    78,
    47,
    16,
    482,
    451,
    420,
    389,
    358,
    327,
    296,
    265, //
    234,
    203,
    172,
    141,
    110,
    79,
    48,
    17,
    483,
    452,
    421,
    390,
    359,
    328,
    297,
    266, //
    235,
    204,
    173,
    142,
    111,
    80,
    49,
    18,
    484,
    453,
    422,
    391,
    360,
    329,
    298,
    267, //
    236,
    205,
    174,
    143,
    112,
    81,
    50,
    19,
    485,
    454,
    423,
    392,
    361,
    330,
    299,
    268, //
    237,
    206,
    175,
    144,
    113,
    82,
    51,
    20,
    486,
    455,
    424,
    393,
    362,
    331,
    300,
    269, //
    238,
    207,
    176,
    145,
    114,
    83,
    52,
    21,
    487,
    456,
    425,
    394,
    363,
    332,
    301,
    270, //
    239,
    208,
    177,
    146,
    115,
    84,
    53,
    22,
    488,
    457,
    426,
    395,
    364,
    333,
    302,
    271, //
    240,
    209,
    178,
    147,
    116,
    85,
    54,
    23,
    489,
    458,
    427,
    396,
    365,
    334,
    303,
    272, //
    241,
    210,
    179,
    148,
    117,
    86,
    55,
    24,
    490,
    459,
    428,
    397,
    366,
    335,
    304,
    273, //
    242,
    211,
    180,
    149,
    118,
    87,
    56,
    25,
    491,
    460,
    429,
    398,
    367,
    336,
    305,
    274, //
    243,
    212,
    181,
    150,
    119,
    88,
    57,
    26,
    492,
    461,
    430,
    399,
    368,
    337,
    306,
    275, //
    244,
    213,
    182,
    151,
    120,
    89,
    58,
    27,
    493,
    462,
    431,
    400,
    369,
    338,
    307,
    276, //
    245,
    214,
    183,
    152,
    121,
    90,
    59,
    28,
    494,
    463,
    432,
    401,
    370,
    339,
    308,
    277, //
    246,
    215,
    184,
    153,
    122,
    91,
    60,
    29,
    495,
    464,
    433,
    402,
    371,
    340,
    309,
    278, //
    247,
    216,
    185,
    154,
    123,
    92,
    61,
    30,
    496,
    465,
    434,
    403,
    372,
    341,
    310,
    279, //
    248,
    217,
    186,
    155,
    124,
    93,
    62,
    31,
    497,
    466,
    435,
    404,
    373,
    342,
    311,
    280, //
    249,
    218,
    187,
    156,
    125,
    94,
    63,
    498,
    467,
    436,
    405,
    374,
    343,
    312,
    281,
    250, //
    219,
    188,
    157,
    126,
    95,
    499,
    468,
    437,
    406,
    375,
    344,
    313,
    282,
    251,
    220,
    189, //
    158,
    127,
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
    501,
    470, //
    439,
    408,
    377,
    346,
    315,
    284,
    253,
    222,
    191,
    502,
    471,
    440,
    409,
    378,
    347,
    316, //
    285,
    254,
    223,
    503,
    472,
    441,
    410,
    379,
    348,
    317,
    286,
    255,
    504,
    473,
    442,
    411, //
    380,
    349,
    318,
    287,
    505,
    474,
    443,
    412,
    381,
    350,
    319,
    506,
    475,
    444,
    413,
    382, //
    351,
    507,
    476,
    445,
    414,
    383,
    508,
    477,
    446,
    415,
    509,
    478,
    447,
    510,
    479,
    511,
  ];
  static const _scan8x32 = [
    0, 32, 1, 64, 33, 2, 96, 65, 34, 3, 128, 97, 66, 35, 4, 160, //
    129, 98, 67, 36, 5, 192, 161, 130, 99, 68, 37, 6, 224, 193, 162, 131, //
    100, 69, 38, 7, 225, 194, 163, 132, 101, 70, 39, 8, 226, 195, 164, 133, //
    102, 71, 40, 9, 227, 196, 165, 134, 103, 72, 41, 10, 228, 197, 166, 135, //
    104, 73, 42, 11, 229, 198, 167, 136, 105, 74, 43, 12, 230, 199, 168, 137, //
    106, 75, 44, 13, 231, 200, 169, 138, 107, 76, 45, 14, 232, 201, 170, 139, //
    108, 77, 46, 15, 233, 202, 171, 140, 109, 78, 47, 16, 234, 203, 172, 141, //
    110, 79, 48, 17, 235, 204, 173, 142, 111, 80, 49, 18, 236, 205, 174, 143, //
    112, 81, 50, 19, 237, 206, 175, 144, 113, 82, 51, 20, 238, 207, 176, 145, //
    114, 83, 52, 21, 239, 208, 177, 146, 115, 84, 53, 22, 240, 209, 178, 147, //
    116, 85, 54, 23, 241, 210, 179, 148, 117, 86, 55, 24, 242, 211, 180, 149, //
    118, 87, 56, 25, 243, 212, 181, 150, 119, 88, 57, 26, 244, 213, 182, 151, //
    120, 89, 58, 27, 245, 214, 183, 152, 121, 90, 59, 28, 246, 215, 184, 153, //
    122, 91, 60, 29, 247, 216, 185, 154, 123, 92, 61, 30, 248, 217, 186, 155, //
    124,
    93,
    62,
    31,
    249,
    218,
    187,
    156,
    125,
    94,
    63,
    250,
    219,
    188,
    157,
    126, //
    95,
    251,
    220,
    189,
    158,
    127,
    252,
    221,
    190,
    159,
    253,
    222,
    191,
    254,
    223,
    255,
  ];
  // libaom TX_SIZE -> tx units (4x4). Indexed by TX_SIZE (0..18).
  static const _txWideUnit = [
    1, 2, 4, 8, 16, 1, 2, 2, 4, 4, 8, 8, 16, 1, 4, 2, 8, 4, 16, //
  ];
  static const _txHighUnit = [
    1, 2, 4, 8, 16, 2, 1, 4, 2, 8, 4, 16, 8, 4, 1, 8, 2, 16, 4, //
  ];
  // txsize_to_bsize (which BLOCK_SIZE exactly covers a TX_SIZE).
  static const _txToBsize = [
    0, 3, 6, 9, 12, 1, 2, 4, 5, 7, 8, 10, 11, 16, 17, 18, 19, 20, 21, //
  ];
  // get_txsize_entropy_ctx(txSize) = (txsize_sqr_map + txsize_sqr_up_map + 1) >> 1,
  // indexed by TX_SIZE. (The previous table had wrong values for the portrait
  // rect sizes 5/7/9/11/13/15/17, e.g. chroma TX_8X4 must be 1, not 0.)
  static const _txsCtxOf = [
    0, 1, 2, 3, 4, 1, 1, 2, 2, 3, 3, 4, 4, 1, 1, 2, 2, 3, 3, //
  ];
  // max_txsize_rect_lookup (var-tx max tx / LARGEST leaf tx), indexed by
  // BLOCK_SIZE. This is the true libaom table (previously a hand-tuned subset).
  static const _maxRectTx = [
    0,
    5,
    6,
    1,
    7,
    8,
    2,
    9,
    10,
    3,
    11,
    12,
    4,
    4,
    4,
    4,
    13,
    14,
    15,
    16,
    17,
    18, //
  ];
  // txsize_sqr_map (largest square tx contained), indexed by TX_SIZE.
  static const _txSqrMap = [
    0, 1, 2, 3, 4, 0, 0, 1, 1, 2, 2, 3, 3, 0, 0, 1, 1, 2, 2, //
  ];
  // txsize_sqr_up_map (smallest square tx that contains this tx).
  static const _txSqrUp = [
    0, 1, 2, 3, 4, 1, 1, 2, 2, 3, 3, 4, 4, 2, 2, 3, 3, 4, 4, //
  ];
  // 4:2:0 chroma tx (av1_get_max_uv_txsize) + txb_skip chroma off, by BLOCK_SIZE.
  static const _uvTx420 = [
    0, 0, 0, 0, 5, 6, 1, 7, 8, 2, 9, 10, 3, 3, 3, 3, 5, 6, 13, 14, 15, 16, //
  ];
  static const _chromaSkipOff420 = [
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 10, 10, 10, 7, 7, 7, 7, 7, 7, //
  ];
  // size_group_lookup (y_mode ctx for an intra block inside an inter frame).
  static const _sizeGroupLookup = [
    0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 0, 0, 1, 1, 2, 2, //
  ];
  // uv2y (get_uv_mode): UV_PREDICTION_MODE -> intra mode, UV_CFL_PRED(13) -> DC.
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];
  // txb_skip context table [top][left] (both clamped 0..4).
  static const _txbSkipCtxTbl = [
    1, 2, 2, 2, 3, //
    2, 4, 4, 4, 5, //
    2, 4, 4, 4, 5, //
    2, 4, 4, 4, 5, //
    3, 5, 5, 5, 6, //
  ];
  // av1_eob_group_start.
  static const _eobGroupStart = [0, 1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513];
  static const _eobOffsetBits = [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];

  static const _subsize = {
    3: [3, 2, 1, 0, 0, 0, 0, 0, 0, 0],
    6: [6, 5, 4, 3, 5, 5, 4, 4, 17, 16],
    9: [9, 8, 7, 6, 8, 8, 7, 7, 19, 18],
    12: [12, 11, 10, 9, 11, 11, 10, 10, 21, 20],
  };

  // CDF context layout.
  static const cPart = 0; // [g0..3][ctx0..3] cPart+g*4+ctx, 0..15
  static const cSkip = 16; // 16..18
  static const cIsInter = 19; // 19..22
  static const cSref = 23; // [ctx0..2][sub0..5] cSref+ctx*6+sub, 23..40
  static const cNewMv = 41; // 41..46
  static const cZeroMv = 47; // 47..48
  static const cRefMv = 49; // 49..64
  static const cDrl = 65; // 65..67
  static const cJoint = 68;
  static const cSign = 69; // [comp] 69..70
  static const cClasses = 71; // 71..72
  static const cClass0 = 73; // 73..74
  static const cClass0Fp = 75; // [comp][d] 75..78
  static const cFp = 79; // 79..80
  static const cClass0Hp = 81; // 81..82
  static const cHp = 83; // 83..84
  static const cBits = 85; // [comp][i] 85..104
  // residual coeff contexts (generic, appended after mode-info 0..104).
  // Generalized to all luma tx sizes used by the inter repros (TX_4X4/TX_8X8/
  // TX_16X8/TX_16X16) + var-tx. Luma coeff banks span txsCtx {0,1,2}, chroma is
  // txb_skip only (all-zero chroma in scope, so no chroma coeff banks). Layout:
  // txsize_log2_minus4 (eob_pt slot) + txb_skip context table.
  static const _eobMSOf = [
    0, 2, 4, 6, 6, 1, 1, 3, 3, 5, 5, 6, 6, 2, 2, 4, 4, 6, 6, //
  ];
  static const cTxbSkip =
      105; // txbSkipCdf[txsCtx 0..2][skipCtx 0..12], 3*13=39
  static const cInterTx4 = 144; // interExtTxCdf[1][0] (16-sym, TX_4X4)
  static const cInterTx8 = 145; // interExtTxCdf[1][1] (16-sym, TX_8X8 + rect)
  static const cInterTx16 = 146; // interExtTxCdf[2][2] (12-sym, TX_16X16)
  static const cEobPt = 147; // eobPtCdf[eobMS 0..6][pt0][ctx 0..1], 7*2=14
  static const cEobExtra =
      161; // eobExtraCdf[txsCtx 0..2][pt0][ctx 0..8], 3*9=27
  static const cBaseEob =
      188; // coeffBaseEobCdf[txsCtx 0..2][pt0][0..3], 3*4=12
  static const cBase = 200; // coeffBaseCdf[txsCtx 0..2][pt0][0..41], 3*42=126
  static const cBr = 326; // coeffBrCdf[txsCtx 0..2][pt0][0..20], 3*21=63
  static const cDcSign = 389; // dcSignCdf[pt0][0..2], 3
  static const cTxfmPart = 392; // txfmPartitionCdf[0..20], 21
  static const cBypass = 413; // fixed [16384,0] bypass (signs/golomb/eob bits)
  // chroma (plane-type 1) coeff banks, for non-zero chroma residual.
  static const cEobPt1 = 414; // eobPtCdf[eobMS 0..6][pt1][ctx 0..1], 14
  static const cEobExtra1 = 428; // eobExtraCdf[txsCtx 0..2][pt1][ctx 0..8], 27
  static const cBaseEob1 = 455; // coeffBaseEobCdf[txsCtx 0..2][pt1][0..3], 12
  static const cBase1 = 467; // coeffBaseCdf[txsCtx 0..2][pt1][0..41], 126
  static const cBr1 = 593; // coeffBrCdf[txsCtx 0..2][pt1][0..20], 63
  static const cDcSign1 = 656; // dcSignCdf[pt1][0..2], 3
  // TX_32X32 (txsCtx 3) luma coeff banks. APPENDED after the plane-type-1
  // banks so the packed txsCtx {0,1,2} slices above are untouched. TX_32X32 is
  // luma-only in scope (its 4:2:0 chroma is TX_16X16 -> txsCtx 2), so no
  // plane-type-1 variant is needed here.
  static const cTxbSkip3 = 659; // txbSkipCdf[3][skipCtx 0..12], 13
  static const cEobExtra3 = 672; // eobExtraCdf[3][pt0][ctx 0..8], 9
  static const cBaseEob3 = 681; // coeffBaseEobCdf[3][pt0][0..3], 4
  static const cBase3 = 685; // coeffBaseCdf[3][pt0][0..41], 42
  static const cBr3 = 727; // coeffBrCdf[3][pt0][0..20], 21
  static const cInterTx32 =
      748; // interExtTxCdf[3][3] (2-sym, TX_32X32 DCT_IDTX)
  // intra-block-in-inter-frame mode-info CDFs (read_intra_block_mode_info).
  static const cYMode = 749; // yModeCdf[sizeGroup 0..3] (13-sym)
  static const cUvMode = 753; // uvModeCdf[cflAllowed 0..1][yMode 0..12] (13/14)
  static const cAngle = 779; // angleDeltaCdf[dirMode-1, 0..7] (7-sym)
  // compound (2-reference) mode-info CDFs.
  static const cSkipMode = 787; // skipModeCdf[ctx 0..2] (2-sym)
  static const cCompInter =
      790; // compInterCdf[ctx 0..4] (2-sym) reference_select
  // explicit-compound (comp_mode==1) ref-pair + mode + type CDFs.
  static const cCompRefType = 795; // compRefTypeCdf[ctx 0..4] (2-sym)
  static const cUniCompRef =
      800; // uniCompRefCdf[ctx 0..2][sub 0..2], 9 (2-sym)
  static const cCompRef = 809; // compRefCdf[ctx 0..2][sub 0..2], 9 (2-sym)
  static const cCompBwdRef =
      818; // compBwdRefCdf[ctx 0..2][sub 0..1], 6 (2-sym)
  static const cInterCompMode =
      824; // interCompoundModeCdf[ctx 0..7] (8-sym), 8
  static const cCompGroupIdx = 832; // compGroupIdxCdf[ctx 0..5] (2-sym), 6
  static const cCompoundType = 838; // compoundTypeCdf[bSize 0..21] (2-sym), 22
  static const cWedgeIdx = 860; // wedgeIdxCdf[bSize 0..21] (16-sym), 22
  // motion_mode: obmcCdf[bSize 0..21] (2-sym: SIMPLE vs OBMC), read when
  // is_motion_mode_switchable && OBMC-eligible && warp NOT allowed. The 3-sym
  // motionModeCdf (SIMPLE/OBMC/WARP) path is a future extension gated on
  // allow_warped_motion + find_warp_samples (deferred, OBMC-only repro has
  // allow_warped_motion == 0).
  static const cObmc = 882; // obmcCdf[bSize 0..21] (2-sym), 22
  // motion_mode 3-value SIMPLE/OBMC/WARP CDF, read when the block is warp-
  // eligible (allow_warped_motion && !force_integer_mv && num_warp_samples>=1).
  // otherwise the 2-value obmcCdf above is read.
  static const cMotionMode = 904; // motionModeCdf[bSize 0..21] (3-sym), 22
  // interintra CDFs (single-ref). interIntraCdf[BLOCK_SIZE_GROUPS 0..3] (2-sym),
  // interIntraModeCdf[group 0..3] (4-sym: DC/V/H/SMOOTH), wedgeInterIntraCdf
  // [bSize 0..21] (2-sym). The wedge index reuses the existing cWedgeIdx bank
  // (wedgeIdxCdf[bSize], 16-sym), shared with compound wedge.
  static const cInterIntra = 926; // interIntraCdf[group 0..3], 4
  static const cInterIntraMode = 930; // interIntraModeCdf[group 0..3], 4
  static const cWedgeInterIntra = 934; // wedgeInterIntraCdf[bSize 0..21], 22
  // inter ext-tx set 3 (DCT_IDTX, 2-sym) for the non-32-square tx sizes whose
  // enclosing square is TX_32X32: interExtTxCdf[3][1] (8x32/32x8) and
  // interExtTxCdf[3][2] (16x32/32x16). interExtTxCdf[3][3] is cInterTx32 (748).
  static const cInterTx32Sq1 = 956; // interExtTxCdf[3][1] (2-sym)
  static const cInterTx32Sq2 = 957; // interExtTxCdf[3][2] (2-sym)
  static const numCtx = 958;
  static const maxSyms = 16;
  // Temporal motion field grid dimension for a 64x64 SB (miN>>1 = 8) and its
  // cell count. tpl positions always land in [0, miRows>>1) x [0, miCols>>1).
  static const _tplDim = 8;
  static const _tplN = _tplDim * _tplDim;

  HarborInterFrameWalk({
    this.maxBytes = 64,
    this.txCoeffSizes = const [0, 1, 2],
    this.enableTmvp = false,
    this.enableGlobalMotion = false,
    String? name,
  }) : super('HarborInterFrameWalk', name: name ?? 'inter_frame_walk') {
    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    createPort('allow_hp', PortDirection.input);
    createPort('force_integer_mv', PortDirection.input);
    createPort('tx_mode_select', PortDirection.input);
    // Compound (REFERENCE_MODE_SELECT) frame controls. skip_mode_present enables
    // the per-block skip_mode flag. ref_mode_select enables the comp_mode
    // (reference_select) flag. skip_ref0/1 = fh.skipModeFrame (the fixed compound
    // ref pair used by a skip_mode block).
    createPort('skip_mode_present', PortDirection.input);
    createPort('ref_mode_select', PortDirection.input);
    createPort('skip_ref0', PortDirection.input, width: 3);
    createPort('skip_ref1', PortDirection.input, width: 3);
    // seq flag gating the explicit-compound comp_type read (comp_group_idx).
    // enableJntComp (COMPOUND_DISTWTD via compound_idx) is assumed false in
    // scope (all target frames have enableJntComp == false). comp_group_idx == 0
    // therefore resolves to COMPOUND_AVERAGE without a compound_idx symbol.
    createPort('enable_masked_compound', PortDirection.input);
    // motion_mode (OBMC) controls. mm_switchable = fh.isMotionModeSwitchable.
    // allow_warped_motion gates the (deferred) 3-value SIMPLE/OBMC/WARP read -
    // when 0, an OBMC-eligible block reads the 2-value obmcCdf (SIMPLE vs OBMC).
    createPort('mm_switchable', PortDirection.input);
    createPort('allow_warped_motion', PortDirection.input);
    // seq flag gating interintra prediction (single-ref only). When set, a
    // single-ref, non-skip-mode block of an interintra-allowed size reads the
    // interintra flag (+ mode, wedge flag, wedge index) after its MV resolves,
    // before motion_mode. SW `seq.enableInterintraCompound`.
    createPort('enable_interintra', PortDirection.input);
    // Per-ref-frame sign bias (bit i = refFrameSignBias[i]), used by the compound
    // ref-mv candidate padding to negate cross-sign-bias neighbour MVs.
    createPort('sign_bias', PortDirection.input, width: 8);
    createPort('cdf_in', PortDirection.input, width: numCtx * maxSyms * 16);
    createPort('nsyms_in', PortDirection.input, width: numCtx * 5);
    // Global-motion models for refs LAST..ALTREF (SW gmType[1..7] / gmParams[1..7]
    // stored at index ref-1). gm_type: 7 x 2-bit type (0 IDENTITY / 1 TRANSLATION
    // / 2 ROTZOOM / 3 AFFINE). gm_mat: 7 x 6 x int32 warp matrix (WARPEDMODEL_PREC
    // _BITS=16). A block's GLOBALMV/GLOBAL_GLOBALMV MV + the ref-mv-stack global
    // candidates derive from the per-ref model via HarborGlobalMv. Only created
    // (and elaborated) when global motion is wired.
    if (enableGlobalMotion) {
      createPort('gm_type', PortDirection.input, width: 7 * 2);
      createPort('gm_mat', PortDirection.input, width: 7 * 6 * 32);
    }

    if (enableTmvp) {
      // Temporal MV field for this frame (produced by HarborMotionField, fed as
      // SW-golden test inputs for this gate). 8x8 per-8x8 grid for a 64x64 SB.
      createPort('use_ref_frame_mvs', PortDirection.input);
      createPort('tpl_valid', PortDirection.input, width: _tplN);
      createPort('tpl_mvrow', PortDirection.input, width: _tplN * 16);
      createPort('tpl_mvcol', PortDirection.input, width: _tplN * 16);
      createPort('tpl_refoff', PortDirection.input, width: _tplN * 6);
      // cur_off[ref] = get_relative_dist(cur, refOrder[ref]) for ref 1..7 (8-bit
      // signed), the projection numerator for a block's decoded ref0.
      createPort('cur_off', PortDirection.input, width: 7 * 8);
    }

    addOutput('done');
    addOutput('sym_count', width: 12);
    addOutput('sym_valid');
    addOutput('rng', width: 16);
    addOutput('block_valid');
    addOutput('blk_r', width: 5);
    addOutput('blk_c', width: 5);
    addOutput('blk_bs', width: 5);
    addOutput('blk_mode', width: 5);
    addOutput('blk_ref0', width: 3);
    addOutput('blk_mvrow', width: 16);
    addOutput('blk_mvcol', width: 16);
    addOutput('blk_modectx', width: 8);
    addOutput('blk_count', width: 4);
    // Compound block outputs (blk_ref1 = -1 -> stored as 0 for single-ref).
    addOutput('blk_ref1', width: 3);
    addOutput('blk_mvrow1', width: 16);
    addOutput('blk_mvcol1', width: 16);
    addOutput('blk_comptype', width: 2);
    addOutput('blk_skipmode');
    // motion_mode of the block (0 SIMPLE, 1 OBMC, 2 WARP: WARP decode deferred).
    addOutput('blk_motionmode', width: 2);
    // interintra of the block: flag, mode (0 DC/1 V/2 H/3 SMOOTH), use_wedge,
    // wedge index. Valid on the block_valid pulse, 0 when not interintra.
    addOutput('blk_interintra');
    addOutput('blk_iimode', width: 2);
    addOutput('blk_iiwedge');
    addOutput('blk_iiwedgeidx', width: 4);
    // Residual verification outputs (pulsed on res_valid when a non-skip block's
    // luma txb finishes coeff decode).
    addOutput('res_valid');
    addOutput('res_eob', width: 11);
    addOutput('res_txtype', width: 5);
    addOutput('res_txsize', width: 3);

    final clk = input('clk');
    final reset = input('reset');
    const miN = 16;
    const cW = 5;
    const oW = 8; // signed offset width (two's complement)

    final ec = HarborOdEcDecoder(maxSyms: maxSyms, numCtx: numCtx, name: 'ec');
    addSubModule(ec);
    final ecw = ec.ctxWidth;

    // byte window + cursor
    final buf = [
      for (var i = 0; i < maxBytes; i++) Logic(name: 'b_$i', width: 8),
    ];
    final cursor = Logic(name: 'cursor', width: (maxBytes + 4).bitLength);
    Logic byteAt(Logic ix) {
      Logic v = buf.last;
      for (var i = maxBytes - 2; i >= 0; i--) {
        v = mux(ix.eq(Const(i, width: cursor.width)), buf[i], v);
      }
      return mux(
        ix.gte(Const(maxBytes, width: cursor.width)),
        Const(0, width: 8),
        v,
      );
    }

    final ecInit = Logic(name: 'ec_init');
    final ecLoad = Logic(name: 'ec_load');
    final ecDecode = Logic(name: 'ec_decode');
    final ecCtx = Logic(name: 'ec_ctx', width: ecw);
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

    final cdfInBits = input('cdf_in');
    final nsymsInBits = input('nsyms_in');
    Logic cdfForCtx(Logic ctx) {
      Logic v = cdfInBits.getRange(
        (numCtx - 1) * maxSyms * 16,
        numCtx * maxSyms * 16,
      );
      for (var c = numCtx - 2; c >= 0; c--) {
        v = mux(
          ctx.eq(Const(c, width: ctx.width)),
          cdfInBits.getRange(c * maxSyms * 16, (c + 1) * maxSyms * 16),
          v,
        );
      }
      return v;
    }

    Logic nsymsForCtx(Logic ctx) {
      Logic v = nsymsInBits.getRange((numCtx - 1) * 5, numCtx * 5);
      for (var c = numCtx - 2; c >= 0; c--) {
        v = mux(
          ctx.eq(Const(c, width: ctx.width)),
          nsymsInBits.getRange(c * 5, c * 5 + 5),
          v,
        );
      }
      return v;
    }

    Logic rom(List<int> tbl, Logic idx, int w) {
      Logic v = Const(tbl.last, width: w);
      for (var i = tbl.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), Const(tbl[i], width: w), v);
      }
      return v;
    }

    Logic miWideOf(Logic bs) => rom(_miWide, bs, 6);
    Logic miHighOf(Logic bs) => rom(_miHigh, bs, 6);

    // per-mi grids
    List<Logic> grid(String nm, int w) => [
      for (var i = 0; i < miN * miN; i++) Logic(name: '${nm}_$i', width: w),
    ];
    final miInter = grid('mi_int', 1);
    final miRef0 = grid('mi_r0', 3);
    final miMode = grid('mi_md', 5);
    final miBs = grid('mi_bs', 5);
    final miMvR = grid('mi_mvr', 16);
    final miMvC = grid('mi_mvc', 16);
    // Compound per-mi grids (2nd ref). miRef1==0 means "no second ref" (SW -1).
    // valid compound second refs are 1..7 so 0 is safe as the sentinel.
    final miRef1 = grid('mi_r1', 3);
    final miMvR1 = grid('mi_mvr1', 16);
    final miMvC1 = grid('mi_mvc1', 16);
    final miSkipMode = grid('mi_skm', 1);
    // comp_group_idx per mi (0 for single-ref / non-masked, used by a later
    // compound block's _compGroupIdxContext).
    final miCompGrp = grid('mi_cgrp', 1);
    // interintra marker per mi. In libaom an interintra block sets
    // ref_frame[1] = INTRA_FRAME (0), whereas a pure single-ref block sets
    // ref_frame[1] = NONE_FRAME (-1). HW collapses both onto miRef1==0, so this
    // 1-bit grid preserves the distinction the warp-sample scan needs
    // (av1_findSamples requires ref_frame[1] == NONE_FRAME, excluding
    // interintra neighbours).
    final miII = grid('mi_ii', 1);
    // read grid at signed (r,c), returns 0 if any coord out of [0,16).
    Logic gridRd(List<Logic> g, Logic rS, Logic cS, int w) {
      final oob =
          rS[oW - 1] |
          cS[oW - 1] |
          rS.gte(Const(miN, width: oW)) |
          cS.gte(Const(miN, width: oW));
      final r = rS.getRange(0, 4);
      final c = cS.getRange(0, 4);
      final addr =
          ((r.zeroExtend(9) * Const(miN, width: 9)).getRange(0, 9) +
                  c.zeroExtend(9))
              .getRange(0, 9);
      Logic v = g.last;
      for (var i = g.length - 2; i >= 0; i--) {
        v = mux(addr.eq(Const(i, width: 9)), g[i], v);
      }
      return mux(oob, Const(0, width: w), v);
    }

    // miBlockSize at (r,c): inside? miBs : 3
    Logic miBsOf(Logic rS, Logic cS) {
      final oob =
          rS[oW - 1] |
          cS[oW - 1] |
          rS.gte(Const(miN, width: oW)) |
          cS.gte(Const(miN, width: oW));
      return mux(oob, Const(3, width: 5), gridRd(miBs, rS, cS, 5));
    }

    Logic insideOf(Logic rS, Logic cS) =>
        ~(rS[oW - 1] |
            cS[oW - 1] |
            rS.gte(Const(miN, width: oW)) |
            cS.gte(Const(miN, width: oW)));

    // above/left ctx arrays
    final abovePart = [
      for (var i = 0; i < miN; i++) Logic(name: 'ap_$i', width: 5),
    ];
    final leftPart = [
      for (var i = 0; i < miN; i++) Logic(name: 'lp_$i', width: 5),
    ];
    final aboveSkip = [for (var i = 0; i < miN; i++) Logic(name: 'as_$i')];
    final leftSkip = [for (var i = 0; i < miN; i++) Logic(name: 'ls_$i')];
    Logic arrRd(List<Logic> a, Logic idx, int w) {
      Logic v = a.last;
      for (var i = a.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), a[i], v);
      }
      return v;
    }

    // partition stack
    const dStack = 48;
    final spW = (dStack + 1).bitLength;
    final stR = [
      for (var i = 0; i < dStack; i++) Logic(name: 'str_$i', width: cW),
    ];
    final stC = [
      for (var i = 0; i < dStack; i++) Logic(name: 'stc_$i', width: cW),
    ];
    final stB = [
      for (var i = 0; i < dStack; i++) Logic(name: 'stb_$i', width: 5),
    ];
    final sp = Logic(name: 'sp', width: spW);
    Logic stackTop(List<Logic> arr) {
      final top = (sp - Const(1, width: spW)).getRange(0, spW);
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(top.eq(Const(i, width: spW)), arr[i], v);
      }
      return v;
    }

    List<Conditional> writeStack(Logic pos, Logic r, Logic c, Logic bs) => [
      for (var slot = 0; slot < dStack; slot++)
        If(
          pos.eq(Const(slot, width: spW)),
          then: [stR[slot] < r, stC[slot] < c, stB[slot] < bs],
        ),
    ];

    // leaf plan (up to 4 block leaves per partition: HORZ4/VERT4).
    final lr = [for (var i = 0; i < 4; i++) Logic(name: 'lr_$i', width: cW)];
    final lc = [for (var i = 0; i < 4; i++) Logic(name: 'lc_$i', width: cW)];
    final lbs = [for (var i = 0; i < 4; i++) Logic(name: 'lbs_$i', width: 5)];
    final leafN = Logic(name: 'leaf_n', width: 3);
    final emitIdx = Logic(name: 'emit_idx', width: 3);

    final nr = Logic(name: 'nr', width: cW);
    final nc = Logic(name: 'nc', width: cW);
    final nbs = Logic(name: 'nbs', width: 5);

    // block-decode regs
    final br = Logic(name: 'br', width: cW);
    final bc = Logic(name: 'bc', width: cW);
    final bbs = Logic(name: 'bbs', width: 5);
    final ref0R = Logic(name: 'ref0_r', width: 3);
    final modeR = Logic(name: 'mode_r', width: 5);
    // compound (2-ref) block registers
    final ref1R = Logic(
      name: 'ref1_r',
      width: 3,
    ); // 0 = single-ref (no 2nd ref)
    final skipModeReg = Logic(
      name: 'skip_mode_r',
    ); // this block's skip_mode flag
    // motion_mode of the current single-ref block (0 SIMPLE / 1 OBMC).
    final motionModeReg = Logic(name: 'motion_mode_r', width: 2);
    // overlappable-neighbour scan (av1_count_overlappable_neighbors): scan the
    // above row then the left col, stepping by neighbour size. mmHasOv records
    // whether ANY overlappable inter neighbour exists (count > 0).
    final mmScan = Logic(name: 'mm_scan', width: cW);
    final mmHasOv = Logic(name: 'mm_has_ov');
    final compTypeReg = Logic(
      name: 'comp_type_r',
      width: 2,
    ); // 0 AVERAGE (scope)
    final compGrpReg = Logic(name: 'comp_grp_r'); // comp_group_idx (0/1)
    // interintra (single-ref) decode registers: flag, mode (0 DC/1 V/2 H/3
    // SMOOTH), use_wedge flag, wedge index (0..15).
    final iiReg = Logic(name: 'ii_r');
    final iiModeReg = Logic(name: 'ii_mode_r', width: 2);
    final iiWedgeReg = Logic(name: 'ii_wedge_r');
    final iiWedgeIdxReg = Logic(name: 'ii_widx_r', width: 4);
    // explicit-compound ref-pair decode phase (bidir/unidir tree walk).
    final crPhase = Logic(name: 'cr_phase', width: 3);
    final mvRow1Reg = Logic(name: 'mv_row1_r', width: 16);
    final mvCol1Reg = Logic(name: 'mv_col1_r', width: 16);
    // compound-extra (process_compound_ref_mv_candidate) accumulators: first
    // exact-ref-match MV + first other-ref (sign-adjusted) MV, per compound ref.
    final ceIdx = Logic(name: 'ce_idx', width: oW);
    final cePhase = Logic(name: 'ce_phase'); // 0 = row scan, 1 = col scan
    final ce0IdF = Logic(name: 'ce0_id_f');
    final ce0IdR = Logic(name: 'ce0_id_r', width: 16);
    final ce0IdC = Logic(name: 'ce0_id_c', width: 16);
    final ce0DfF = Logic(name: 'ce0_df_f');
    final ce0DfR = Logic(name: 'ce0_df_r', width: 16);
    final ce0DfC = Logic(name: 'ce0_df_c', width: 16);
    final ce1IdF = Logic(name: 'ce1_id_f');
    final ce1IdR = Logic(name: 'ce1_id_r', width: 16);
    final ce1IdC = Logic(name: 'ce1_id_c', width: 16);
    final ce1DfF = Logic(name: 'ce1_df_f');
    final ce1DfR = Logic(name: 'ce1_df_r', width: 16);
    final ce1DfC = Logic(name: 'ce1_df_c', width: 16);
    // second exact-match / other-ref accumulators (compList[1]).
    final ce0Id2F = Logic(name: 'ce0_id2_f');
    final ce0Id2R = Logic(name: 'ce0_id2_r', width: 16);
    final ce0Id2C = Logic(name: 'ce0_id2_c', width: 16);
    final ce0Df2F = Logic(name: 'ce0_df2_f');
    final ce0Df2R = Logic(name: 'ce0_df2_r', width: 16);
    final ce0Df2C = Logic(name: 'ce0_df2_c', width: 16);
    final ce1Id2F = Logic(name: 'ce1_id2_f');
    final ce1Id2R = Logic(name: 'ce1_id2_r', width: 16);
    final ce1Id2C = Logic(name: 'ce1_id2_c', width: 16);
    final ce1Df2F = Logic(name: 'ce1_df2_f');
    final ce1Df2R = Logic(name: 'ce1_df2_r', width: 16);
    final ce1Df2C = Logic(name: 'ce1_df2_c', width: 16);
    // intra-block (in inter frame) mode-info regs.
    final isIntraReg = Logic(name: 'is_intra_r');
    final yModeReg = Logic(name: 'ymode_r', width: 5);
    final uvModeReg = Logic(name: 'uvmode_r', width: 5);
    final srIdx = Logic(name: 'sr_idx', width: 3);
    final drlIdxR = Logic(name: 'drl_idx_r', width: 3);
    final symCnt = Logic(name: 'sym_cnt', width: 12);
    final symValid = Logic(name: 'sym_valid_r');
    final blockValid = Logic(name: 'block_valid_r');

    // read_mv regs
    final jointReg = Logic(name: 'joint_r', width: 2);
    final needRow = Logic(name: 'need_row');
    final needCol = Logic(name: 'need_col');
    final compReg = Logic(name: 'comp_r');
    final signReg = Logic(name: 'sign_r');
    final mvClassReg = Logic(name: 'mvclass_r', width: 4);
    final dAcc = Logic(name: 'd_acc', width: 11);
    final bitIx = Logic(name: 'bit_i', width: 4);
    final frReg = Logic(name: 'fr_r', width: 2);
    final hpReg = Logic(name: 'hp_r');
    final predR = Logic(name: 'pred_r', width: 16);
    final predC = Logic(name: 'pred_c', width: 16);
    final mvRowReg = Logic(name: 'mv_row_r', width: 16);
    final mvColReg = Logic(name: 'mv_col_r', width: 16);

    // residual coeff decode registers
    final skipReg = Logic(name: 'skip_r');
    final txClassReg = Logic(name: 'txclass_r', width: 2);
    final txTypeReg = Logic(name: 'txtype_r', width: 5);
    // last decoded luma leaf tx_type, forced onto the chroma txbs of the block
    // (co-located luma, DCT for all-zero luma). Reset to DCT at each block.
    final blkLumaTxType = Logic(name: 'blk_luma_txtype', width: 5);
    final eobReg = Logic(name: 'eob_r', width: 11);
    final eobPtReg = Logic(name: 'eobpt_r', width: 4);
    final cIdx = Logic(name: 'cidx_r', width: 8); // scan index (0..255)
    final levelReg = Logic(name: 'level_r', width: 8);
    final brIdxR = Logic(name: 'br_idx_r', width: 3);
    final offBitsR = Logic(name: 'off_bits_r', width: 4);
    final eobExtraR = Logic(name: 'eob_extra_r', width: 11);
    final bypIdxR = Logic(name: 'byp_idx_r', width: 4);
    final csignReg = Logic(name: 'csign_r');
    final pbLevelReg = Logic(name: 'pb_level_r', width: 21);
    final golLeadR = Logic(name: 'gol_lead_r', width: 6);
    final golXR = Logic(name: 'gol_x_r', width: 21);
    final golCntR = Logic(name: 'gol_cnt_r', width: 6);
    final resEobReg = Logic(name: 'res_eob_r', width: 11);
    final resTxTypeReg = Logic(name: 'res_txtype_r', width: 5);
    final resValidReg = Logic(name: 'res_valid_r');
    // The padded level buffers now live inside each HarborCoeffContext as an
    // addressed memory (memBacked). The walk drives one write port per active
    // cc (below) and reads the ~9 template neighbours + cur_level as O(1)
    // addressed reads, instead of maintaining register arrays + whole-buffer
    // muxes here. This is what makes TX_32X32/64X64 residual tractable to sim.

    // current-txb geometry registers (runtime tx size + plane).
    final curTxSize = Logic(name: 'cur_tx', width: 5);
    final curPlane = Logic(name: 'cur_plane', width: 2);
    final curAOff = Logic(name: 'cur_aoff', width: 5); // px>>2 (0..15 luma)
    final curLOff = Logic(name: 'cur_loff', width: 5); // py>>2
    final culLevelReg = Logic(name: 'cul_r', width: 7); // culLevel for EC write
    final dcValNeg = Logic(name: 'dc_neg'); // dc coeff sign for EC (bit6/7)
    final dcValPos = Logic(name: 'dc_pos');

    // per-plane entropy-context arrays (culLevel, dc-sign in bits 6..7). Luma
    // is indexed by 4x4-unit col/row within the 64x64 SB (0..15), chroma (4:2:0)
    // 0..7. Written by _setEntropyCtx, read by _getTxbCtx. Reset per skip block.
    final aboveEC0 = [
      for (var i = 0; i < 16; i++) Logic(name: 'aec0_$i', width: 8),
    ];
    final leftEC0 = [
      for (var i = 0; i < 16; i++) Logic(name: 'lec0_$i', width: 8),
    ];
    final aboveEC1 = [
      for (var i = 0; i < 8; i++) Logic(name: 'aec1_$i', width: 8),
    ];
    final leftEC1 = [
      for (var i = 0; i < 8; i++) Logic(name: 'lec1_$i', width: 8),
    ];
    final aboveEC2 = [
      for (var i = 0; i < 8; i++) Logic(name: 'aec2_$i', width: 8),
    ];
    final leftEC2 = [
      for (var i = 0; i < 8; i++) Logic(name: 'lec2_$i', width: 8),
    ];
    // txfm-context arrays (neighbour tx width/height in pixels, init 64 at edge).
    final aboveTxfm = [
      for (var i = 0; i < 16; i++) Logic(name: 'atx_$i', width: 7),
    ];
    final leftTxfm = [
      for (var i = 0; i < 16; i++) Logic(name: 'ltx_$i', width: 7),
    ];

    // var-tx leaf list (up to 4 leaves for the BLOCK_8X8 maxTx=TX_8X8 tree, the
    // recursion is depth<=1 for the tractable var-tx repro). Each leaf carries
    // its tx size and mi-unit offset (idy,idx) within the block.
    final vtSz = [for (var i = 0; i < 4; i++) Logic(name: 'vtsz_$i', width: 5)];
    final vtIdy = [
      for (var i = 0; i < 4; i++) Logic(name: 'vtidy_$i', width: 5),
    ];
    final vtIdx = [
      for (var i = 0; i < 4; i++) Logic(name: 'vtidx_$i', width: 5),
    ];
    final vtN = Logic(name: 'vt_n', width: 3);
    final vtCur = Logic(
      name: 'vt_cur',
      width: 3,
    ); // current leaf being coeff-read
    final vtSplitR = Logic(name: 'vt_split_r'); // txfm_partition split decision
    final vtNodeR = Logic(
      name: 'vt_node_r',
      width: 5,
    ); // current tree node mi pos
    final vtNodeC = Logic(name: 'vt_node_c', width: 5);
    final vtNodeTx = Logic(name: 'vt_node_tx', width: 5);
    final resPlane = Logic(
      name: 'res_plane',
      width: 2,
    ); // 0=Y,1=U,2=V residual phase

    // find_mv_refs regs
    final fmStackR = [
      for (var i = 0; i < 8; i++) Logic(name: 'fsr_$i', width: 16),
    ];
    final fmStackC = [
      for (var i = 0; i < 8; i++) Logic(name: 'fsc_$i', width: 16),
    ];
    final fmStackW = [
      for (var i = 0; i < 8; i++) Logic(name: 'fsw_$i', width: 16),
    ];
    final fmCount = Logic(name: 'fm_count', width: 4);
    final fmNearestCount = Logic(name: 'fm_nc', width: 4);
    final fmModeCtx = Logic(name: 'fm_mctx', width: 8);
    final fmRowMatch = Logic(name: 'fm_rm', width: 5);
    final fmColMatch = Logic(name: 'fm_cm', width: 5);
    final fmNewmv = Logic(name: 'fm_nmv', width: 5);
    final fmNearestMatch = Logic(name: 'fm_nmatch', width: 2);
    final fmProcRows = Logic(name: 'fm_pr', width: oW);
    final fmProcCols = Logic(name: 'fm_pc', width: oW);
    // TMVP temporal-scan regs (only used when enableTmvp).
    final tBlkRow = Logic(name: 't_blkrow', width: oW); // signed sample offset
    final tBlkCol = Logic(name: 't_blkcol', width: oW);
    final tPhase = Logic(name: 't_phase'); // 0=primary grid, 1=extended
    final tExtIdx = Logic(name: 't_extidx', width: 2); // 0..2 extended sample
    final tAvail = Logic(name: 't_avail'); // (0,0) sample produced a candidate
    final fmGlobalMv = Logic(name: 'fm_gmv'); // temporal globalmv mode-ctx bit
    final tHitReg = Logic(name: 't_hit'); // current sample hit a valid tpl cell
    final tGmvReg = Logic(name: 't_gmvfar'); // |proj|>=16 (globalmv trigger)
    final tZeroReg = Logic(name: 't_zero'); // current sample is primary (0,0)
    // scan engine
    final scDir = Logic(name: 'sc_dir'); // 0 row,1 col
    final scOff = Logic(name: 'sc_off', width: oW); // signed
    final scI = Logic(name: 'sc_i', width: oW);
    final scEnd = Logic(name: 'sc_end', width: oW);
    final scMatchCol = Logic(name: 'sc_mcol'); // accumulate into colMatch?
    final scRet = Logic(name: 'sc_ret', width: 8);
    final scIsBlk = Logic(name: 'sc_isblk');
    final scUpdProc = Logic(name: 'sc_updproc');
    final scCountNew = Logic(
      name: 'sc_cnew',
    ); // count newmv (nearest phase only)
    final scBlkR = Logic(name: 'sc_blkr', width: oW); // blk-scan abs position
    final scBlkC = Logic(name: 'sc_blkc', width: oW);
    // add-candidate scratch
    final acR = Logic(name: 'ac_r', width: 16);
    final acC = Logic(name: 'ac_c', width: 16);
    final acW = Logic(name: 'ac_w', width: 16);
    final acNew = Logic(name: 'ac_new');
    final acMatch = Logic(name: 'ac_match');
    final acCol = Logic(name: 'ac_col');
    // sort engine
    final sortStart = Logic(name: 'sort_start', width: 4);
    final sortEnd = Logic(name: 'sort_end', width: 4);
    final sortIdx = Logic(name: 'sort_idx', width: 4);
    final sortLen = Logic(name: 'sort_len', width: 4);
    final sortNr = Logic(name: 'sort_nr', width: 4);
    final sortRet = Logic(name: 'sort_ret', width: 8);
    // clamp
    final clampIdx = Logic(name: 'clamp_idx', width: 4);
    // outer-scan step index (2..3)
    final outIdx = Logic(name: 'out_idx', width: 3);
    // drl loop phase
    final drlPhase = Logic(name: 'drl_phase', width: 3);

    // global-motion MV (gm_get_motion_vector) for the current block
    // Two combinational HarborGlobalMv instances: one keyed on the block's ref0,
    // one on ref1 (compound). Each selects the per-ref model (gm_type/gm_mat,
    // stored at index ref-1) and evaluates the warp centre at (br,bc,bbs). The
    // 1/8-pel result (low 16 bits) feeds the GLOBALMV/GLOBAL_GLOBALMV mode MV and
    // the ref-mv-stack global candidates, replacing the former forced (0,0).
    final bsWidePx = rom(_bsWide, bbs, 8);
    final bsHighPx = rom(_bsHigh, bbs, 8);
    Logic gmSelType(Logic refVal) {
      final idx = (refVal - Const(1, width: 3)).getRange(0, 3);
      Logic v = input('gm_type').getRange(0, 2);
      for (var r = 1; r < 7; r++) {
        v = mux(
          idx.eq(Const(r, width: 3)),
          input('gm_type').getRange(r * 2, r * 2 + 2),
          v,
        );
      }
      return v;
    }

    Logic gmSelMat(Logic refVal, int j) {
      final idx = (refVal - Const(1, width: 3)).getRange(0, 3);
      Logic v = input('gm_mat').getRange(j * 32, j * 32 + 32);
      for (var r = 1; r < 7; r++) {
        v = mux(
          idx.eq(Const(r, width: 3)),
          input('gm_mat').getRange((r * 6 + j) * 32, (r * 6 + j) * 32 + 32),
          v,
        );
      }
      return v;
    }

    (Logic, Logic, Logic) mkGlobalMv(String nm, Logic refVal) {
      final g = HarborGlobalMv(name: nm);
      addSubModule(g);
      g.input('gm_type').srcConnection! <= gmSelType(refVal);
      for (var j = 0; j < 6; j++) {
        g.input('mat$j').srcConnection! <= gmSelMat(refVal, j);
      }
      g.input('block_wide').srcConnection! <= bsWidePx;
      g.input('block_high').srcConnection! <= bsHighPx;
      g.input('mi_r').srcConnection! <= br.zeroExtend(16);
      g.input('mi_c').srcConnection! <= bc.zeroExtend(16);
      g.input('allow_hp').srcConnection! <= input('allow_hp');
      g.input('force_integer').srcConnection! <= input('force_integer_mv');
      // gmType[ref] > TRANSLATION (i.e. ROTZOOM/AFFINE): gates motion_mode/interp.
      final nonTrans = gmSelType(refVal).gt(Const(1, width: 2));
      return (
        g.output('mv_row').getRange(0, 16),
        g.output('mv_col').getRange(0, 16),
        nonTrans,
      );
    }

    final Logic gmv0R, gmv0C, gm0NonTrans, gmv1R, gmv1C;
    if (enableGlobalMotion) {
      final (r0, c0, nt0) = mkGlobalMv('gm_ref0', ref0R);
      final (r1, c1, nt1) = mkGlobalMv('gm_ref1', ref1R);
      gmv0R = r0;
      gmv0C = c0;
      gm0NonTrans = nt0;
      gmv1R = r1;
      gmv1C = c1;
      // ref1 non-trans is not a motion_mode gate (SW keys on ref0), reference it
      // so analyze does not flag the unused compound-ref global-warp predicate.
      final _ = nt1;
    } else {
      // Identity global motion: GLOBALMV -> (0,0), no warp/motion_mode gating.
      gmv0R = Const(0, width: 16);
      gmv0C = Const(0, width: 16);
      gmv1R = Const(0, width: 16);
      gmv1C = Const(0, width: 16);
      gm0NonTrans = Const(0);
    }
    // A GLOBALMV/GLOBAL_GLOBALMV block whose ref0 global model is non-translational
    // forces SIMPLE motion_mode with NO symbol (SW _motionModeAllowed: block >= 8x8
    // and force_integer_mv==0). The mm states are only reached for >= 8x8 blocks.
    final isGlobalMode =
        modeR.eq(Const(15, width: 5)) | modeR.eq(Const(23, width: 5));
    final globalMmSuppress =
        isGlobalMode & gm0NonTrans & ~input('force_integer_mv');

    final pli = Logic(name: 'pli', width: ecw);

    final allowHp = input('allow_hp');
    final forceInt = input('force_integer_mv');
    final txModeSel = input('tx_mode_select');
    final skipModePresent = input('skip_mode_present');
    final refModeSelect = input('ref_mode_select');
    final skipRef0 = input('skip_ref0');
    final skipRef1 = input('skip_ref1');
    final maskedEn = input('enable_masked_compound');
    final signBias = input('sign_bias');
    final useSubpel = ~forceInt;
    final useHp = ~forceInt & allowHp;
    Logic signBiasOf(Logic ref) {
      Logic v = signBias[7];
      for (var i = 6; i >= 0; i--) {
        v = mux(ref.eq(Const(i, width: 3)), signBias[i], v);
      }
      return v;
    }

    // FSM states
    const sIdle = 0, sPreload = 1, sInit = 2, sPop = 3, sPartDec = 4, sPartCap = 5, sLeaf = 6, sSkipDec = 7, sSkipCap = 8, sIsInterDec = 9, sIsInterCap = 10, sSrDec = 11, sSrCap = 12, sFmv = 13, sModeDec = 14, sModeNewCap = 15, sZeroDec = 16, sZeroCap = 17, sRefDec = 18, sRefCap = 19, sDrl = 20, sDrlDec = 21, sDrlCap = 22, sPred = 23, sJointDec = 24, sJointCap = 25, sSignDec = 26, sSignCap = 27, sClassDec = 28, sClassCap = 29, sClass0Dec = 30, sClass0Cap = 31, sBitsDec = 32, sBitsCap = 33, sFpDec = 34, sFpCap = 35, sHpDec = 36, sHpCap = 37, sCompAsm = 38, sWriteMi = 39,
    // find_mv_refs (phase 1 = scanRow(-1) runs inline in sFmv)
    sFmvN2 = 41, // nearest col -1
    sFmvN3 = 42, // top-right blk
    sFmvNearW = 43, sFmvTL = 44, // top-left blk
    sFmvOuter = 45, sFmvModeCtx = 46, sFmvSort0 = 47, sFmvSort1 = 48, sSortPass = 49, sClamp = 52, sScanStep = 53, sScanAdd = 54, sDone = 55,
    // residual coeff decode
    rYSkipDec = 56, rYSkipCap = 57, rTxTypeDec = 58, rTxTypeCap = 59, rEobPtDec = 60, rEobPtCap = 61, rExtra = 62, rExtraCap = 63, rByp = 64, rBypDec = 65, rBypCap = 66, rBaseDec = 67, rBaseCap = 68, rBrDec = 69, rBrCap = 70, rNext = 71, rPbCheck = 72, rPbSignDec = 73, rPbSignCap = 74, rPbGolChk = 75, rPbGolLeadDec = 76, rPbGolLeadCap = 77, rPbGolReadDec = 78, rPbGolReadCap = 79, rPbDeq = 80, rPbNext = 81, rBypLoad = 87, rPbSignLoad = 88, rPbGolLeadLoad = 89, rPbGolReadLoad = 90, rExtraDec = 91,
    // var-tx txfm_partition tree + generic residual sequencing
    rResInit = 92, // decide var-tx vs largest, set up leaf iteration
    rTxfmPartDec = 93, rTxfmPartCap = 94, rVtEmit = 95, // build leaf list from split decision
    rLeafNext = 96, // advance to next luma leaf (coeff-read)
    rLeafSetup = 97, // set curTxSize/aOff/lOff for the leaf, clear levels
    rEcWrite = 99, // setEntropyCtx after a luma txb completes
    // chroma coeff decode (U then V, full coeff path via the shared
    // coeff FSM with plane-type-1 CDF banks + forced tx_type).
    rCSkipDec = 100, rCSkipCap = 101, rCEcWrite = 102, // chroma setEntropyCtx + advance plane (U->V->done)
    // intra block (in inter frame) mode info: y_mode, angle_delta_y,
    // uv_mode, angle_delta_uv (no CFL/palette/filter-intra in scope).
    sIntraY = 103, sIntraYCap = 104, sIntraAngleY = 105, sIntraAngleYCap = 106, sIntraUv = 107, sIntraUvCap = 108, sIntraAngleUv = 109, sIntraAngleUvCap = 110,
    // compound (2-ref) mode info
    sSkipModeDec = 111, sSkipModeCap = 112, sCompModeDec = 113, sCompModeCap = 114,
    // compound find_mv_refs: process_compound_ref_mv_candidate padding. The
    // nearest compound scans yield 0 candidates for the scoped frame (its
    // single compound block has no compound neighbours), so the count==0
    // padding branch runs directly. Row scan then col scan then resolve.
    sCompExtraInit = 115, sCompExtraStep = 116, sCompResolve = 117,
    // explicit-compound (comp_mode==1) ref pair + mode + type
    sCompRefTypeDec = 118, sCompRefTypeCap = 119, sCompRefDec = 120, sCompRefCap = 121, sInterCompModeDec = 122, sInterCompModeCap = 123, sCompDrl = 124, sCompDrlDec = 125, sCompDrlCap = 126, sCompResolveMv = 127, sCompTypeGrpDec = 128, sCompTypeGrpCap = 129, sCompTypeSymDec = 130, sCompTypeSymCap = 131, sMaskTypeDec = 132, sMaskTypeCap = 133, sMaskTypeLoad = 134, sWedgeIdxDec = 135, sWedgeIdxCap = 136, sWedgeSignDec = 137, sWedgeSignCap = 138, sWedgeSignLoad = 139,
    // single-ref extra candidates (process_single_ref_mv_candidate)
    sSrExtra = 140, sSrExtraR0 = 141, sSrExtraAdd0 = 142, sSrExtraR1 = 143, sSrExtraAdd1 = 144,
    // motion_mode (OBMC) decode
    // sMmChk: eligibility + start overlappable-neighbour scan. sMmAbove /
    // sMmLeft: scan above row / left col (variable step) accumulating
    // mmHasOv. sMmResolve: allowed => read obmc, else SIMPLE. sMmDec/Cap:
    // read the 2-value obmc symbol.
    sMmChk = 145, sMmAbove = 146, sMmLeft = 147, sMmResolve = 148, sMmDec = 149, sMmCap = 150,
    // 3-value SIMPLE/OBMC/WARP motion_mode read (warp-eligible blocks).
    sMmDec3 = 151, sMmCap3 = 152,
    // TMVP temporal-candidate scan (_addTemporalMvs), between the nearest
    // scan (sFmvNearW) and the top-left/outer scan (sFmvTL). sTmvpDisp:
    // dispatch the next sample (primary grid then the 3 extended samples,
    // with the checkSbBorder gate). sTmvpSample: compute pos/tr/tc, look up
    // tplValid, project via HarborMvProjection + lowerMvPrecision, register
    // the candidate. sTmvpAdd: dedup/weight/push into the stack, update the
    // (0,0) availability + globalmv mode-context bit, advance.
    sTmvpDisp = 160, sTmvpSample = 161, sTmvpAdd = 162,
    // interintra (single-ref) entropy decode, inserted after the MV resolves
    // and before motion_mode. sIIChk: eligibility gate. sIIDec/Cap: the
    // interintra flag. sIIModeDec/Cap: the 4-symbol mode. sIIWedgeDec/Cap:
    // the wedge flag (only when wedge is usable for the block size).
    // sIIWedgeIdxDec/Cap: the 16-symbol wedge index (reuses wedgeIdxCdf).
    sIIChk = 163, sIIDec = 164, sIICap = 165, sIIModeDec = 166, sIIModeCap = 167, sIIWedgeDec = 168, sIIWedgeCap = 169, sIIWedgeIdxDec = 170, sIIWedgeIdxCap = 171;
    const stW = 8;
    // fixed uniform bypass ICDF (od_ec_decode_bool_q15).
    Logic bypassCdf() {
      var v = BigInt.zero;
      v |= BigInt.from(16384) << 0;
      return Const(v, width: maxSyms * 16);
    }

    final st = Logic(name: 'st', width: stW);

    // combinational geometry for current block (br,bc,bbs)
    final bw4 = miWideOf(bbs);
    final bh4 = miHighOf(bbs);
    // signed helpers
    Logic sx(Logic v) => v.zeroExtend(oW); // zero-extend small unsigned to oW
    Logic sConst(int v) => Const(v & ((1 << oW) - 1), width: oW);
    Logic sltO(Logic a, Logic b) =>
        (a - b).getRange(0, oW)[oW - 1]; // a<b signed
    Logic absO(Logic v) =>
        mux(v[oW - 1], (~v + Const(1, width: oW)).getRange(0, oW), v);
    Logic sclamp(Logic v, Logic lo, Logic hi) =>
        mux(sltO(v, lo), lo, mux(sltO(hi, v), hi, v));

    final rowAdj = (bh4.lt(Const(2, width: 6)) & br[0]);
    final colAdj = (bw4.lt(Const(2, width: 6)) & bc[0]);
    final brS = sx(br);
    final bcS = sx(bc);
    final mBaseR =
        (mux(bh4.lt(Const(2, width: 6)), sConst(-4), sConst(-6)) +
                rowAdj.zeroExtend(oW))
            .getRange(0, oW);
    final maxRow = mux(
      br.eq(Const(0, width: cW)),
      sConst(0),
      sclamp(
        mBaseR,
        (sConst(0) - brS).getRange(0, oW),
        (sConst(15) - brS).getRange(0, oW),
      ),
    );
    final mBaseC =
        (mux(bw4.lt(Const(2, width: 6)), sConst(-4), sConst(-6)) +
                colAdj.zeroExtend(oW))
            .getRange(0, oW);
    final maxCol = mux(
      bc.eq(Const(0, width: cW)),
      sConst(0),
      sclamp(
        mBaseC,
        (sConst(0) - bcS).getRange(0, oW),
        (sConst(15) - bcS).getRange(0, oW),
      ),
    );

    // hasTopRight
    final maskRow = br.getRange(0, 4);
    final maskCol = bc.getRange(0, 4);
    final bsMax = mux(bh4.lt(bw4), bw4, bh4).getRange(0, 6);
    Logic hasTopRightCalc() {
      Logic mr(int b) => (maskRow.zeroExtend(6) & Const(b, width: 6)).or();
      Logic mc(int b) => (maskCol.zeroExtend(6) & Const(b, width: 6)).or();
      Logic mrL(Logic b) => (maskRow.zeroExtend(6) & b).or();
      Logic mcL(Logic b) => (maskCol.zeroExtend(6) & b).or();
      var hasTr = ~(mrL(bsMax) & mcL(bsMax));
      Logic brk = Const(0);
      for (final bsv in [1, 2, 4, 8]) {
        final bsc = Const(bsv, width: 6);
        final active = ~bsc.lt(bsMax) & ~brk; // bsv>=bsMax and not broken
        final colHit = mc(bsv);
        final both = mc(2 * bsv) & mr(2 * bsv);
        final setFalse = active & colHit & both;
        hasTr = mux(setFalse, Const(0), hasTr);
        brk = brk | (active & (setFalse | ~colHit));
      }
      final w = bw4, h = bh4;
      final vlast =
          ((bc.zeroExtend(6) + w).getRange(0, 6) &
                  (h - Const(1, width: 6)).getRange(0, 6))
              .or();
      final hfirst =
          (maskRow.zeroExtend(6) & (w - Const(1, width: 6)).getRange(0, 6))
              .or();
      hasTr = mux(w.lt(h), mux(vlast, Const(1), hasTr), hasTr);
      hasTr = mux(h.lt(w), mux(hfirst, Const(0), hasTr), hasTr);
      return hasTr;
    }

    final hasTopRight = hasTopRightCalc();
    final trCok = (bcS + sx(bw4)).getRange(0, oW).lt(Const(miN, width: oW));
    final hasTopRightMv = hasTopRight & ~br.eq(Const(0, width: cW)) & trCok;

    // partition ctx
    final partBsl = (rom(_miWideLog2, nbs, 3) - Const(1, width: 3)).getRange(
      0,
      3,
    );
    final partGroup = (Const(4, width: 3) - rom(_miWideLog2, nbs, 3)).getRange(
      0,
      2,
    );
    final apVal = arrRd(abovePart, nc, 5);
    final lpVal = arrRd(leftPart, nr, 5);
    final aboveBit =
        (~nr.eq(Const(0, width: cW))) &
        ((apVal >> partBsl) & Const(1, width: 5)).or();
    final leftBit =
        (~nc.eq(Const(0, width: cW))) &
        ((lpVal >> partBsl) & Const(1, width: 5)).or();
    final partCtx = ((leftBit.zeroExtend(2) << 1) + aboveBit.zeroExtend(2))
        .getRange(0, 2);
    final partCtxIdx =
        (Const(cPart, width: ecw) +
                (partGroup.zeroExtend(ecw) * Const(4, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                partCtx.zeroExtend(ecw))
            .getRange(0, ecw);

    // skip ctx
    final skAbove = mux(
      br.eq(Const(0, width: cW)),
      Const(0),
      arrRd(aboveSkip, bc, 1),
    );
    final skLeft = mux(
      bc.eq(Const(0, width: cW)),
      Const(0),
      arrRd(leftSkip, br, 1),
    );
    final skipCtx = (skAbove.zeroExtend(2) + skLeft.zeroExtend(2)).getRange(
      0,
      2,
    );

    // is_inter ctx
    final hasAbove = ~br.eq(Const(0, width: cW));
    final hasLeft = ~bc.eq(Const(0, width: cW));
    final brm1 = (brS - sConst(1)).getRange(0, oW);
    final bcm1 = (bcS - sConst(1)).getRange(0, oW);
    final aInter = gridRd(miInter, brm1, bcS, 1);
    final lInter = gridRd(miInter, brS, bcm1, 1);
    final aIntra = hasAbove & ~aInter;
    final lIntra = hasLeft & ~lInter;
    final isInterCtx = mux(
      hasAbove & hasLeft,
      mux(
        lIntra & aIntra,
        Const(3, width: 2),
        mux<Logic>(lIntra | aIntra, Const(1, width: 2), Const(0, width: 2)),
      ),
      mux(
        hasAbove | hasLeft,
        (mux(hasAbove, aIntra, lIntra)).zeroExtend(2) << 1,
        Const(0, width: 2),
      ),
    );

    // single_ref neighbour counts (_collectNeighborRefCounts): counts miRef0 AND
    // miRef1 (when the neighbour is compound, miRef1 >= refLast) of both edges.
    final aRef = gridRd(miRef0, brm1, bcS, 3);
    final lRef = gridRd(miRef0, brS, bcm1, 3);
    final aRef1 = gridRd(miRef1, brm1, bcS, 3);
    final lRef1 = gridRd(miRef1, brS, bcm1, 3);
    Logic cntRef(int refv) {
      final a0 = hasAbove & aInter & aRef.eq(Const(refv, width: 3));
      final a1 =
          hasAbove &
          aInter &
          aRef1.gte(Const(1, width: 3)) &
          aRef1.eq(Const(refv, width: 3));
      final l0 = hasLeft & lInter & lRef.eq(Const(refv, width: 3));
      final l1 =
          hasLeft &
          lInter &
          lRef1.gte(Const(1, width: 3)) &
          lRef1.eq(Const(refv, width: 3));
      return (a0.zeroExtend(3) +
              a1.zeroExtend(3) +
              l0.zeroExtend(3) +
              l1.zeroExtend(3))
          .getRange(0, 3);
    }

    final c1 = cntRef(1), c2 = cntRef(2), c3 = cntRef(3), c4 = cntRef(4);
    final c5 = cntRef(5), c6 = cntRef(6), c7 = cntRef(7);
    final fwdCnt =
        (c1.zeroExtend(3) +
                c2.zeroExtend(3) +
                c3.zeroExtend(3) +
                c4.zeroExtend(3))
            .getRange(0, 3);
    final bwdCnt = (c5.zeroExtend(3) + c6.zeroExtend(3) + c7.zeroExtend(3))
        .getRange(0, 3);
    Logic ctx3(Logic a, Logic b) => mux(
      a.eq(b),
      Const(1, width: 2),
      mux<Logic>(a.lt(b), Const(0, width: 2), Const(2, width: 2)),
    );
    final ll2 = (c1 + c2).getRange(0, 3);
    final l3g = (c3 + c4).getRange(0, 3);
    final brf56 = (c5 + c6).getRange(0, 3); // BWDREF + ALTREF2 counts
    // single_ref sub-CDF contexts (av1 read_single_ref, per sub-index srIdx):
    // 0 p1 fwd-vs-bwd, 1 p2 {BWD,ALTREF2}-vs-ALTREF, 2 p3, 3 p4,
    // 4 p5, 5 p6 BWD-vs-ALTREF2. The backward sub-contexts (1, 5) were
    // previously absent (masked while every neighbour ref was LAST).
    final srCtxV = mux(
      srIdx.eq(Const(0, width: 3)),
      ctx3(fwdCnt, bwdCnt),
      mux(
        srIdx.eq(Const(1, width: 3)),
        ctx3(brf56, c7),
        mux(
          srIdx.eq(Const(2, width: 3)),
          ctx3(ll2, l3g),
          mux(
            srIdx.eq(Const(3, width: 3)),
            ctx3(c1, c2),
            mux(srIdx.eq(Const(5, width: 3)), ctx3(c5, c6), ctx3(c3, c4)),
          ),
        ),
      ),
    );
    final srCtxIdx =
        (Const(cSref, width: ecw) +
                (srCtxV.zeroExtend(ecw) * Const(6, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                srIdx.zeroExtend(ecw))
            .getRange(0, ecw);

    // inter_mode ctx
    final newmvCtx = (fmModeCtx & Const(0x7, width: 8)).getRange(0, 3);
    final zeroCtx = ((fmModeCtx >> 3) & Const(0x1, width: 8)).getRange(0, 1);
    final refmvCtx = ((fmModeCtx >> 4) & Const(0xf, width: 8)).getRange(0, 4);

    // compound (2-ref) contexts
    // _isCompRefAllowed: block >= 8x8 px. (bw4,bh4 >= 2 mi units.)
    final compRefAllowed =
        bw4.gte(Const(2, width: 6)) & bh4.gte(Const(2, width: 6));
    // skip_mode ctx = miSkipMode(above) + miSkipMode(left).
    final aSkm = mux(hasAbove, gridRd(miSkipMode, brm1, bcS, 1), Const(0));
    final lSkm = mux(hasLeft, gridRd(miSkipMode, brS, bcm1, 1), Const(0));
    final skipModeCtx = (aSkm.zeroExtend(2) + lSkm.zeroExtend(2)).getRange(
      0,
      2,
    );
    final skipModeCtxIdx =
        (Const(cSkipMode, width: ecw) + skipModeCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );
    // comp_mode ctx (av1_get_reference_mode_context). second = neighbour has a
    // 2nd ref (miRef1 >= refLast), back = neighbour ref0 is backward (>= 5).
    final aSec = aInter & aRef1.gte(Const(1, width: 3));
    final lSec = lInter & lRef1.gte(Const(1, width: 3));
    final aBack = aInter & aRef.gte(Const(5, width: 3));
    final lBack = lInter & lRef.gte(Const(5, width: 3));
    final ciBoth = mux(
      ~aSec & ~lSec,
      (aBack ^ lBack).zeroExtend(3),
      mux(
        ~aSec,
        (Const(2, width: 3) + (aBack | ~aInter).zeroExtend(3)).getRange(0, 3),
        mux(
          ~lSec,
          (Const(2, width: 3) + (lBack | ~lInter).zeroExtend(3)).getRange(0, 3),
          Const(4, width: 3),
        ),
      ),
    );
    // single-edge: present edge = above if hasAbove else left.
    final ciSec = mux(hasAbove, aSec, lSec);
    final ciBack = mux(hasAbove, aBack, lBack);
    final ciSingle = mux(~ciSec, ciBack.zeroExtend(3), Const(3, width: 3));
    final compInterCtx = mux(
      hasAbove & hasLeft,
      ciBoth,
      mux(hasAbove | hasLeft, ciSingle, Const(1, width: 3)),
    );
    final compInterCtxIdx =
        (Const(cCompInter, width: ecw) + compInterCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );

    // motion_mode (OBMC) eligibility + overlappable-neighbour scan
    // obmcCdf indexed by block size.
    final obmcCtxIdx = (Const(cObmc, width: ecw) + bbs.zeroExtend(ecw))
        .getRange(0, ecw);
    final motionModeCtxIdx =
        (Const(cMotionMode, width: ecw) + bbs.zeroExtend(ecw)).getRange(0, ecw);
    // OBMC-eligible: is_motion_mode_switchable && block >= 8x8 (bw4,bh4 >= 2).
    // (single-ref only: compound/intra never reach the motion_mode states,
    // global-mv non-translation is out of scope. Global motion disabled.)
    final mmEligible =
        input('mm_switchable') &
        bw4.gte(Const(2, width: 6)) &
        bh4.gte(Const(2, width: 6));
    final mmScanS = mmScan.zeroExtend(oW);
    Logic clip16(Logic v) =>
        mux(v.gt(Const(16, width: 6)), Const(16, width: 6), v);
    // foreach_overlappable_nb_above: neighbour block at (br-1, mmScan). Step by
    // neighbour width (clamped 16). A 4px neighbour (step 1) is paired and the
    // bottom-right (odd col) is the tested representative.
    final mmAbNr = (brS - sConst(1)).getRange(0, oW);
    final mmAbStepRaw = clip16(miWideOf(miBsOf(mmAbNr, mmScanS)));
    final mmAbPair = mmAbStepRaw.eq(Const(1, width: 6));
    final mmAbBase = mux(mmAbPair, (mmScan & Const(0x1E, width: cW)), mmScan);
    final mmAbTest = mux(
      mmAbPair,
      (mmAbBase + Const(1, width: cW)).getRange(0, cW),
      mmScan,
    );
    final mmAbStep = mux(mmAbPair, Const(2, width: 6), mmAbStepRaw);
    final mmAbInter = gridRd(miInter, mmAbNr, mmAbTest.zeroExtend(oW), 1);
    final mmAbNext = (mmAbBase.zeroExtend(6) + mmAbStep).getRange(0, cW);
    final mmAbEnd = clip16((bc.zeroExtend(6) + bw4).getRange(0, 6));
    final mmAbInRange = mmScan.zeroExtend(6).lt(mmAbEnd);
    // foreach_overlappable_nb_left: neighbour block at (mmScan, bc-1). Step by
    // neighbour height.
    final mmLtNc = (bcS - sConst(1)).getRange(0, oW);
    final mmLtStepRaw = clip16(miHighOf(miBsOf(mmScanS, mmLtNc)));
    final mmLtPair = mmLtStepRaw.eq(Const(1, width: 6));
    final mmLtBase = mux(mmLtPair, (mmScan & Const(0x1E, width: cW)), mmScan);
    final mmLtTest = mux(
      mmLtPair,
      (mmLtBase + Const(1, width: cW)).getRange(0, cW),
      mmScan,
    );
    final mmLtStep = mux(mmLtPair, Const(2, width: 6), mmLtStepRaw);
    final mmLtInter = gridRd(miInter, mmLtTest.zeroExtend(oW), mmLtNc, 1);
    final mmLtNext = (mmLtBase.zeroExtend(6) + mmLtStep).getRange(0, cW);
    final mmLtEnd = clip16((br.zeroExtend(6) + bh4).getRange(0, 6));
    final mmLtInRange = mmScan.zeroExtend(6).lt(mmLtEnd);

    // find_warp_samples: num_warp_samples >= 1 (av1_findSamples)
    // Gates the 3-value SIMPLE/OBMC/WARP motion_mode read vs the 2-value obmc
    // read. Only the >=1 predicate matters for decode (the affine model itself is
    // derived, not coded). Faithful port of av1_findSamples: above scan, left
    // scan (each single-sample when the block fits the neighbour, else stepped
    // loop), plus top-left and top-right (hasTopRight) corners. tRowStart /
    // tColStart == 0 and tColEnd == miCols == 16 (single tile, exact frame).
    // av1_findSamples requires ref_frame[0] == ref and ref_frame[1] ==
    // NONE_FRAME. Single-ref stores miRef1==0, an interintra neighbour also has
    // miRef1==0 but ref_frame[1] == INTRA_FRAME (miII==1), so it must be
    // excluded (it is not a valid warp sample).
    Logic wsSingle(Logic rS, Logic cS) =>
        gridRd(miInter, rS, cS, 1) &
        gridRd(miRef0, rS, cS, 3).eq(ref0R) &
        gridRd(miRef1, rS, cS, 3).eq(Const(0, width: 3)) &
        ~gridRd(miII, rS, cS, 1);
    // above neighbour geometry at (r-1, c).
    final wsSbw = miWideOf(miBsOf(brm1, bcS)); // neighbour width (mi)
    final wsSbwMask = (wsSbw - Const(1, width: 6)).getRange(0, 6);
    final wsAboveSingle = ~bw4.gt(wsSbw); // bw4 <= sbw
    final wsCMod = (bc.zeroExtend(6) & wsSbwMask).getRange(0, 6); // c % sbw
    final wsColOffNeg = ~wsCMod.eq(Const(0, width: 6)); // colOffset < 0
    final wsDoTrClear = (wsSbw - wsCMod).getRange(0, 6).gt(bw4); // +sbw > w4
    // left neighbour geometry at (r, c-1).
    final wsSbh = miHighOf(miBsOf(brS, bcm1));
    final wsSbhMask = (wsSbh - Const(1, width: 6)).getRange(0, 6);
    final wsLeftSingle = ~bh4.gt(wsSbh);
    final wsRMod = (br.zeroExtend(6) & wsSbhMask).getRange(0, 6);
    final wsRowOffNeg = ~wsRMod.eq(Const(0, width: 6));
    // stepped-loop scans (block wider/taller than the neighbour). Unrolled to
    // the mi-grid width, positions step by each visited neighbour's dim.
    final wsAbLim = mux(
      bw4.lt((Const(16, width: 6) - bc.zeroExtend(6)).getRange(0, 6)),
      bw4,
      (Const(16, width: 6) - bc.zeroExtend(6)).getRange(0, 6),
    );
    Logic wsAboveLoop() {
      Logic acc = Const(0, width: 6), found = Const(0);
      for (var u = 0; u < 16; u++) {
        final pos = (bcS + acc.zeroExtend(oW)).getRange(0, oW);
        found = found | (acc.lt(wsAbLim) & wsSingle(brm1, pos));
        acc = (acc + miWideOf(miBsOf(brm1, pos))).getRange(0, 6);
      }
      return found;
    }

    final wsLtLim = mux(
      bh4.lt((Const(16, width: 6) - br.zeroExtend(6)).getRange(0, 6)),
      bh4,
      (Const(16, width: 6) - br.zeroExtend(6)).getRange(0, 6),
    );
    Logic wsLeftLoop() {
      Logic acc = Const(0, width: 6), found = Const(0);
      for (var u = 0; u < 16; u++) {
        final pos = (brS + acc.zeroExtend(oW)).getRange(0, oW);
        found = found | (acc.lt(wsLtLim) & wsSingle(pos, bcm1));
        acc = (acc + miHighOf(miBsOf(pos, bcm1))).getRange(0, 6);
      }
      return found;
    }

    final wsAboveFound =
        hasAbove & mux(wsAboveSingle, wsSingle(brm1, bcS), wsAboveLoop());
    final wsLeftFound =
        hasLeft & mux(wsLeftSingle, wsSingle(brS, bcm1), wsLeftLoop());
    // doTl cleared by above(single, colOffset<0) or left(single, rowOffset<0).
    final wsDoTl =
        ~(hasAbove & wsAboveSingle & wsColOffNeg) &
        ~(hasLeft & wsLeftSingle & wsRowOffNeg);
    final wsDoTr = ~(hasAbove & wsAboveSingle & wsDoTrClear);
    final wsCPlusW = (bcS + bw4.zeroExtend(oW)).getRange(0, oW);
    final wsTlFound = wsDoTl & hasLeft & hasAbove & wsSingle(brm1, bcm1);
    final wsTrFound =
        wsDoTr &
        hasAbove &
        hasTopRight &
        (bc.zeroExtend(6) + bw4).getRange(0, 6).lt(Const(16, width: 6)) &
        wsSingle(brm1, wsCPlusW);
    // numWarpSamples >= 1.
    final hasWarpSample = wsAboveFound | wsLeftFound | wsTlFound | wsTrFound;

    // explicit-compound ref-pair contexts (read_ref_frames COMPOUND)
    // Neighbour derived predicates (reuse aInter/lInter/aRef/lRef/aRef1/lRef1).
    Logic b5(Logic v) => v.gte(Const(5, width: 3));
    // nbUniComp = has 2nd ref AND both refs same direction (both<5 or both>=5).
    final aUni = aSec & b5(aRef).eq(b5(aRef1));
    final lUni = lSec & b5(lRef).eq(b5(lRef1));
    final aB5 = b5(aRef), lB5 = b5(lRef);
    final backEq = aB5.eq(lB5); // (frfa>=5)==(frfl>=5)
    final eq5 = aRef.eq(Const(5, width: 3)).eq(lRef.eq(Const(5, width: 3)));
    // av1_get_comp_reference_type_context.
    Logic compRefTypeCtxCalc() {
      // both edges present.
      final bothIntra = aIntra & lIntra;
      final oneIntra = aIntra ^ lIntra;
      // when exactly one is intra, the inter side's sec/uni.
      final interSec = mux(aIntra, lSec, aSec);
      final interUni = mux(aIntra, lUni, aUni);
      final oneIntraVal = mux(
        ~interSec,
        Const(2, width: 3),
        (Const(1, width: 3) + (interUni.zeroExtend(3) << 1)).getRange(0, 3),
      );
      // both inter.
      final aSg = ~aSec, lSg = ~lSec; // single-ref neighbours
      final bothSgVal = (Const(1, width: 3) + (backEq.zeroExtend(3) << 1))
          .getRange(0, 3);
      final oneSg = lSg ^ aSg;
      final uniRfc = mux(aSg, lUni, aUni);
      final oneSgVal = mux(
        ~uniRfc,
        Const(1, width: 3),
        (Const(3, width: 3) + backEq.zeroExtend(3)).getRange(0, 3),
      );
      final bothCompVal = mux(
        ~aUni & ~lUni,
        Const(0, width: 3),
        mux(
          ~aUni | ~lUni,
          Const(2, width: 3),
          (Const(3, width: 3) + eq5.zeroExtend(3)).getRange(0, 3),
        ),
      );
      final bothInterVal = mux(
        aSg & lSg,
        bothSgVal,
        mux(oneSg, oneSgVal, bothCompVal),
      );
      final bothPresent = mux(
        bothIntra,
        Const(2, width: 3),
        mux(oneIntra, oneIntraVal, bothInterVal),
      );
      // single edge present.
      final eInter = mux(hasAbove, aInter, lInter);
      final eSec = mux(hasAbove, aSec, lSec);
      final eUni = mux(hasAbove, aUni, lUni);
      final singleVal = mux(
        ~eInter,
        Const(2, width: 3),
        mux(
          ~eSec,
          Const(2, width: 3),
          (eUni.zeroExtend(3) << 2).getRange(0, 3),
        ),
      );
      return mux(
        hasAbove & hasLeft,
        bothPresent,
        mux(hasAbove | hasLeft, singleVal, Const(2, width: 3)),
      );
    }

    final compRefTypeCtx = compRefTypeCtxCalc();
    final compRefTypeCtxIdx =
        (Const(cCompRefType, width: ecw) + compRefTypeCtx.zeroExtend(ecw))
            .getRange(0, ecw);
    // bidir fwd (comp_ref) + bwd (comp_bwdref) sub-CDF contexts. crPhase selects
    // which sub-CDF is being read (0: compRef[0], 1: compRef[1], 2: compRef[2],
    // 3: compBwdRef[0], 4: compBwdRef[1]).
    final crCtxV = mux(
      crPhase.eq(Const(0, width: 3)),
      ctx3(ll2, l3g),
      mux(
        crPhase.eq(Const(1, width: 3)),
        ctx3(c1, c2),
        mux(
          crPhase.eq(Const(2, width: 3)),
          ctx3(c3, c4),
          mux(
            crPhase.eq(Const(3, width: 3)),
            ctx3((c5 + c6).getRange(0, 3), c7),
            ctx3(c5, c6),
          ),
        ),
      ),
    );
    // compRefCdf[ctx][sub]=cCompRef+ctx*3+sub, compBwdRefCdf[ctx][sub]=
    // cCompBwdRef+ctx*2+sub (sub = crPhase-3). Combined index below.
    final crSub = mux(
      crPhase.lt(Const(3, width: 3)),
      crPhase,
      (crPhase - Const(3, width: 3)).getRange(0, 3),
    );
    final crStride = mux<Logic>(
      crPhase.lt(Const(3, width: 3)),
      Const(3, width: ecw),
      Const(2, width: ecw),
    );
    final crBase = mux<Logic>(
      crPhase.lt(Const(3, width: 3)),
      Const(cCompRef, width: ecw),
      Const(cCompBwdRef, width: ecw),
    );
    final crCtxIdx =
        (crBase +
                (crCtxV.zeroExtend(ecw) * crStride).getRange(0, ecw) +
                crSub.zeroExtend(ecw))
            .getRange(0, ecw);
    // uni_comp_ref sub-CDF contexts (unidir, crPhase 0..2 map to sub 0..2).
    final uniCtxV = mux(
      crPhase.eq(Const(0, width: 3)),
      ctx3(fwdCnt, bwdCnt),
      mux(crPhase.eq(Const(1, width: 3)), ctx3(c2, l3g), ctx3(c3, c4)),
    );
    final uniCtxIdx =
        (Const(cUniCompRef, width: ecw) +
                (uniCtxV.zeroExtend(ecw) * Const(3, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                crPhase.zeroExtend(ecw))
            .getRange(0, ecw);
    // comp_group_idx ctx (_compGroupIdxContext). Neighbour contribution:
    // inter & compound -> miCompGrp, inter & single & ref0==ALTREF(7) -> 3.
    Logic cgNb(Logic inter, Logic ref0, Logic ref1, Logic grp, Logic has) {
      final comp = ref1.gte(Const(1, width: 3));
      return mux(
        has & inter,
        mux(
          comp,
          grp.zeroExtend(3),
          mux<Logic>(
            ref0.eq(Const(7, width: 3)),
            Const(3, width: 3),
            Const(0, width: 3),
          ),
        ),
        Const(0, width: 3),
      );
    }

    final aGrp = gridRd(miCompGrp, brm1, bcS, 1);
    final lGrp = gridRd(miCompGrp, brS, bcm1, 1);
    final cgSum =
        (cgNb(aInter, aRef, aRef1, aGrp, hasAbove).zeroExtend(4) +
                cgNb(lInter, lRef, lRef1, lGrp, hasLeft).zeroExtend(4))
            .getRange(0, 4);
    final cgCtx = mux(
      cgSum.lt(Const(5, width: 4)),
      cgSum.getRange(0, 3),
      Const(5, width: 3),
    );
    final compGrpCtxIdx =
        (Const(cCompGroupIdx, width: ecw) + cgCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );
    // compound inter-mode context (_compoundModeContext). fmModeCtx==0 in scope.
    final cmNewmv = (fmModeCtx & Const(0x7, width: 8)).getRange(0, 3);
    final cmRefmv = ((fmModeCtx >> 4) & Const(0xf, width: 8)).getRange(0, 4);
    final cmN = mux(
      cmNewmv.lt(Const(4, width: 3)),
      cmNewmv,
      Const(4, width: 3),
    );
    // compound_mode_ctx_map[3][5], flattened row-major.
    const _compModeCtxMap = [
      0, 1, 1, 1, 1, //
      1, 2, 3, 4, 4, //
      4, 4, 5, 6, 7, //
    ];
    final cmRow = (cmRefmv >> 1).getRange(0, 3);
    final cmFlat =
        ((cmRow.zeroExtend(6) * Const(5, width: 6)).getRange(0, 6) +
                cmN.zeroExtend(6))
            .getRange(0, 6);
    final compModeCtx = rom(_compModeCtxMap, cmFlat, 3);
    final interCompModeCtxIdx =
        (Const(cInterCompMode, width: ecw) + compModeCtx.zeroExtend(ecw))
            .getRange(0, ecw);
    // comp_type sub-CDFs indexed by block size.
    final compoundTypeCtxIdx =
        (Const(cCompoundType, width: ecw) + bbs.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );
    final wedgeIdxCtxIdx = (Const(cWedgeIdx, width: ecw) + bbs.zeroExtend(ecw))
        .getRange(0, ecw);
    // _wedgeUsed: 8<=w<=32 && 8<=h<=32 (mi units 2..8).
    final wedgeUsed =
        bw4.gte(Const(2, width: 6)) &
        bw4.lte(Const(8, width: 6)) &
        bh4.gte(Const(2, width: 6)) &
        bh4.lte(Const(8, width: 6));

    // interintra (single-ref) gates + CDF context indices.
    // _interintraAllowed: BLOCK_8X8..BLOCK_32X32 (square-ish set), bSize 3..9.
    final iiAllowed = bbs.gte(Const(3, width: 5)) & bbs.lte(Const(9, width: 5));
    final iiGroup = rom(_sizeGroupLookup, bbs, 2); // size_group_lookup[bSize]
    final iiCtxIdx = (Const(cInterIntra, width: ecw) + iiGroup.zeroExtend(ecw))
        .getRange(0, ecw);
    final iiModeCtxIdx =
        (Const(cInterIntraMode, width: ecw) + iiGroup.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );
    final iiWedgeCtxIdx =
        (Const(cWedgeInterIntra, width: ecw) + bbs.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );

    // compound ref-mv candidate padding (process_compound_ref_mv_candidate)
    // geometry. miSize = min(min(16,bw4) clamped to miCols-c, min(16,bh4)
    // clamped to miRows-r). One neighbour visited per step (stepped by the
    // neighbour's width [row scan] / height [col scan]).
    final ceMiW0 = mux(bw4.lt(Const(16, width: 6)), bw4, Const(16, width: 6));
    final ceColRem = (Const(16, width: 6) - bc.zeroExtend(6)).getRange(0, 6);
    final ceMiW = mux(ceMiW0.lt(ceColRem), ceMiW0, ceColRem);
    final ceMiH0 = mux(bh4.lt(Const(16, width: 6)), bh4, Const(16, width: 6));
    final ceRowRem = (Const(16, width: 6) - br.zeroExtend(6)).getRange(0, 6);
    final ceMiH = mux(ceMiH0.lt(ceRowRem), ceMiH0, ceRowRem);
    final ceMiSize = mux(ceMiW.lt(ceMiH), ceMiW, ceMiH);
    final ceRR = mux(
      cePhase,
      (brS + ceIdx).getRange(0, oW),
      (brS - sConst(1)).getRange(0, oW),
    );
    final ceCC = mux(
      cePhase,
      (bcS - sConst(1)).getRange(0, oW),
      (bcS + ceIdx).getRange(0, oW),
    );
    final ceInside = insideOf(ceRR, ceCC);
    final ceNbInter = gridRd(miInter, ceRR, ceCC, 1);
    final ceNbRef0 = gridRd(miRef0, ceRR, ceCC, 3);
    final ceNbRef1 = gridRd(miRef1, ceRR, ceCC, 3);
    final ceNbMvR = gridRd(miMvR, ceRR, ceCC, 16);
    final ceNbMvC = gridRd(miMvC, ceRR, ceCC, 16);
    final ceNbMvR1 = gridRd(miMvR1, ceRR, ceCC, 16);
    final ceNbMvC1 = gridRd(miMvC1, ceRR, ceCC, 16);
    final ceNbBs = miBsOf(ceRR, ceCC);
    final ceStep = mux(
      cePhase,
      miHighOf(ceNbBs),
      miWideOf(ceNbBs),
    ).zeroExtend(oW);
    Logic negMv(Logic m) => (~m + Const(1, width: 16)).getRange(0, 16);
    // Per-neighbour (both refs) contribution to the id/df accumulators for a
    // compound target ref `tgt`, with rfIdx0 (ref0) priority over rfIdx1 (ref1).
    // Returns [idHit, idR, idC, dfHit, dfR, dfC].
    List<Logic> ceContrib(Logic tgt) {
      final r0Ex = ceNbInter & ceNbRef0.eq(tgt);
      final r1Ex = ceNbInter & ceNbRef1.eq(tgt);
      final idHit = r0Ex | r1Ex;
      final idR = mux(r0Ex, ceNbMvR, ceNbMvR1);
      final idC = mux(r0Ex, ceNbMvC, ceNbMvC1);
      final r0Ot =
          ceNbInter & ceNbRef0.gte(Const(1, width: 3)) & ~ceNbRef0.eq(tgt);
      final r1Ot =
          ceNbInter & ceNbRef1.gte(Const(1, width: 3)) & ~ceNbRef1.eq(tgt);
      final dfHit = r0Ot | r1Ot;
      final adj0 = signBiasOf(ceNbRef0) ^ signBiasOf(tgt);
      final adj1 = signBiasOf(ceNbRef1) ^ signBiasOf(tgt);
      final r0R = mux(adj0, negMv(ceNbMvR), ceNbMvR);
      final r0C = mux(adj0, negMv(ceNbMvC), ceNbMvC);
      final r1R = mux(adj1, negMv(ceNbMvR1), ceNbMvR1);
      final r1C = mux(adj1, negMv(ceNbMvC1), ceNbMvC1);
      final dfR = mux(r0Ot, r0R, r1R);
      final dfC = mux(r0Ot, r0C, r1C);
      return [idHit, idR, idC, dfHit, dfR, dfC];
    }

    final ce0 = ceContrib(ref0R);
    final ce1 = ceContrib(ref1R);
    // process_single_ref_mv_candidate: for a neighbour at (ceRR,ceCC), each of
    // its two refs (>refIntra) contributes an MV (sign-bias negated vs ref0R),
    // deduped into the stack. Uses the shared ce scan geometry (row/col).
    final srQ0 = ceNbInter & ceNbRef0.gte(Const(1, width: 3));
    final srNeg0 = signBiasOf(ceNbRef0) ^ signBiasOf(ref0R);
    final srR0 = mux(srNeg0, negMv(ceNbMvR), ceNbMvR);
    final srC0 = mux(srNeg0, negMv(ceNbMvC), ceNbMvC);
    final srQ1 = ceNbInter & ceNbRef1.gte(Const(1, width: 3));
    final srNeg1 = signBiasOf(ceNbRef1) ^ signBiasOf(ref0R);
    final srR1 = mux(srNeg1, negMv(ceNbMvR1), ceNbMvR1);
    final srC1 = mux(srNeg1, negMv(ceNbMvC1), ceNbMvC1);
    // lower_mv_precision (force_integer_mv / !allow_hp), matching SW.
    Logic lowerC(Logic v) {
      final absv = mux(v[15], negMv(v), v);
      final aint =
          ((absv + Const(3, width: 16)).getRange(0, 16) &
                  Const(0xFFF8, width: 16))
              .getRange(0, 16);
      final fiRes = mux(v[15], negMv(aint), aint);
      final adj = mux(
        v[15],
        (v + Const(1, width: 16)).getRange(0, 16),
        (v - Const(1, width: 16)).getRange(0, 16),
      );
      final hpRes = mux(v[0], adj, v);
      return mux(forceInt, fiRes, mux(allowHp, v, hpRes));
    }

    // resolved NEAREST compound MVs (compList[0] per ref: exact-match, else
    // other-ref, else the per-ref global MV, then lowered).
    final ceN0R = lowerC(mux(ce0IdF, ce0IdR, mux(ce0DfF, ce0DfR, gmv0R)));
    final ceN0C = lowerC(mux(ce0IdF, ce0IdC, mux(ce0DfF, ce0DfC, gmv0C)));
    final ceN1R = lowerC(mux(ce1IdF, ce1IdR, mux(ce1DfF, ce1DfR, gmv1R)));
    final ceN1C = lowerC(mux(ce1IdF, ce1IdC, mux(ce1DfF, ce1DfC, gmv1C)));
    // compList[1] per ref (stack[1] = second candidate of [refId.., refDiff..,
    // gm..], else the per-ref global MV). Used by compound NEAR modes.
    Logic second(
      Logic id1F,
      Logic id1R,
      Logic id0F,
      Logic df0F,
      Logic df0R,
      Logic df1F,
      Logic df1R,
      Logic gmDef,
    ) => lowerC(
      mux(id1F, id1R, mux(id0F & df0F, df0R, mux(~id0F & df1F, df1R, gmDef))),
    );
    final ceS1R0 = second(
      ce0Id2F,
      ce0Id2R,
      ce0IdF,
      ce0DfF,
      ce0DfR,
      ce0Df2F,
      ce0Df2R,
      gmv0R,
    );
    final ceS1C0 = second(
      ce0Id2F,
      ce0Id2C,
      ce0IdF,
      ce0DfF,
      ce0DfC,
      ce0Df2F,
      ce0Df2C,
      gmv0C,
    );
    final ceS1R1 = second(
      ce1Id2F,
      ce1Id2R,
      ce1IdF,
      ce1DfF,
      ce1DfR,
      ce1Df2F,
      ce1Df2R,
      gmv1R,
    );
    final ceS1C1 = second(
      ce1Id2F,
      ce1Id2C,
      ce1IdF,
      ce1DfF,
      ce1DfC,
      ce1Df2F,
      ce1Df2C,
      gmv1C,
    );
    // compound sub-mode resolve. modeR in 17..24. sub0/sub1 per
    // compound_ref0_mode / compound_ref1_mode. NEAREST -> stack[0], NEAR ->
    // stack[1] (refMvIdx 0 in scope), GLOBAL -> gmv(0,0). (NEW read_mv is a
    // future extension gated by a tractable NEW compound frame.)
    final m17 = modeR.eq(Const(17, width: 5));
    final m18 = modeR.eq(Const(18, width: 5));
    final m19 = modeR.eq(Const(19, width: 5));
    final m20 = modeR.eq(Const(20, width: 5));
    final m21 = modeR.eq(Const(21, width: 5));
    final m22 = modeR.eq(Const(22, width: 5));
    final m23 = modeR.eq(Const(23, width: 5));
    // sub0 NEAREST for 17,19, NEAR for 18,21, GLOBAL for 23.
    final sub0Nearest = m17 | m19;
    final sub0Near = m18 | m21;
    // sub1 NEAREST for 17,20, NEAR for 18,22, GLOBAL for 23.
    final sub1Nearest = m17 | m20;
    final sub1Near = m18 | m22;
    // GLOBAL sub-mode uses the raw (unlowered) per-ref global MV.
    final compMv0R = mux(sub0Nearest, ceN0R, mux(sub0Near, ceS1R0, gmv0R));
    final compMv0C = mux(sub0Nearest, ceN0C, mux(sub0Near, ceS1C0, gmv0C));
    final compMv1R = mux(sub1Nearest, ceN1R, mux(sub1Near, ceS1R1, gmv1R));
    final compMv1C = mux(sub1Nearest, ceN1C, mux(sub1Near, ceS1C1, gmv1C));
    // reference m23 to avoid an unused-signal analyze warning (GLOBAL both).
    final _ = m23;

    // drl ctx from sorted weights and phase
    Logic wSel(Logic i) {
      Logic v = fmStackW.last;
      for (var k = fmStackW.length - 2; k >= 0; k--) {
        v = mux(i.eq(Const(k, width: 4)), fmStackW[k], v);
      }
      return v;
    }

    final drlA = wSel(drlPhase.zeroExtend(4));
    final drlB = wSel(
      (drlPhase.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
    );
    final drlAHi = drlA.gte(Const(640, width: 16));
    final drlBHi = drlB.gte(Const(640, width: 16));
    final drlCtx = mux(
      drlAHi & drlBHi,
      Const(0, width: 2),
      mux(
        drlAHi & ~drlBHi,
        Const(1, width: 2),
        mux<Logic>(~drlAHi & ~drlBHi, Const(2, width: 2), Const(0, width: 2)),
      ),
    );
    final drlCtxIdx = (Const(cDrl, width: ecw) + drlCtx.zeroExtend(ecw))
        .getRange(0, ecw);

    // read_mv ctxs
    final isClass0 = mvClassReg.eq(Const(0, width: 4));
    final signCtx = (Const(cSign, width: ecw) + compReg.zeroExtend(ecw))
        .getRange(0, ecw);
    final classCtx = (Const(cClasses, width: ecw) + compReg.zeroExtend(ecw))
        .getRange(0, ecw);
    final class0Ctx = (Const(cClass0, width: ecw) + compReg.zeroExtend(ecw))
        .getRange(0, ecw);
    final class0FpCtx =
        (Const(cClass0Fp, width: ecw) +
                (compReg.zeroExtend(ecw) << 1) +
                dAcc.getRange(0, 1).zeroExtend(ecw))
            .getRange(0, ecw);
    final fpBase = (Const(cFp, width: ecw) + compReg.zeroExtend(ecw)).getRange(
      0,
      ecw,
    );
    final fpCtx = mux(isClass0, class0FpCtx, fpBase);
    final hpCtx = mux(
      isClass0,
      (Const(cClass0Hp, width: ecw) + compReg.zeroExtend(ecw)).getRange(0, ecw),
      (Const(cHp, width: ecw) + compReg.zeroExtend(ecw)).getRange(0, ecw),
    );
    final bitsCtx =
        (Const(cBits, width: ecw) +
                (compReg.zeroExtend(ecw) * Const(10, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                bitIx.zeroExtend(ecw))
            .getRange(0, ecw);

    // component assembly (av1_read_mv_component)
    final magBase = mux(
      isClass0,
      Const(0, width: 17),
      (Const(2, width: 17) << (mvClassReg + Const(2, width: 4)).getRange(0, 4))
          .getRange(0, 17),
    );
    final tail =
        ((dAcc.zeroExtend(17) << 3) |
            (frReg.zeroExtend(17) << 1) |
            hpReg.zeroExtend(17)) +
        Const(1, width: 17);
    final magFull = (magBase + tail).getRange(0, 16);
    final compVal = mux(signReg, (~magFull + Const(1, width: 16)), magFull);

    // subsize lookup for current node
    Logic subSel(Logic bs, Logic part) {
      Logic tbl(List<int> t) {
        Logic v = Const(t.last, width: 5);
        for (var i = t.length - 2; i >= 0; i--) {
          v = mux(
            part.eq(Const(i, width: part.width)),
            Const(t[i], width: 5),
            v,
          );
        }
        return v;
      }

      return mux(
        bs.eq(Const(3, width: 5)),
        tbl(_subsize[3]!),
        mux(
          bs.eq(Const(6, width: 5)),
          tbl(_subsize[6]!),
          mux(bs.eq(Const(9, width: 5)), tbl(_subsize[9]!), tbl(_subsize[12]!)),
        ),
      );
    }

    final half = (miWideOf(nbs) >> 1).getRange(0, cW);
    final quarter = (miWideOf(nbs) >> 2).getRange(0, cW);
    Logic rPlus(Logic v) => (nr + v).getRange(0, cW);
    Logic cPlus(Logic v) => (nc + v).getRange(0, cW);
    Logic subOf(int p) => subSel(nbs, Const(p, width: 4));

    // planned-leaf helper: queue up to 3 block leaves then go to sLeaf.
    List<Conditional> plan(List<List<Logic>> leaves) => [
      for (var i = 0; i < leaves.length; i++) ...[
        lr[i] < leaves[i][0],
        lc[i] < leaves[i][1],
        lbs[i] < leaves[i][2],
      ],
      leafN < Const(leaves.length, width: 3),
      emitIdx < Const(0, width: 3),
      st < Const(sLeaf, width: stW),
    ];

    // scan geometry (used by sScanStep)
    // current scan position and neighbour lookups computed from scDir/scOff/scI.
    // colOff/rowOff base
    final scAbsOff = absO(scOff);
    final scOffGt1 = scAbsOff.gt(Const(1, width: oW));
    // for row scan: colBase = (|off|>1)?(1 - ((c&1&&bw4<2)?1:0)):0, rr=r+off, cc=c+colBase+i
    final rowColBase = mux(
      scOffGt1,
      (sConst(1) - (bc[0] & bw4.lt(Const(2, width: 6))).zeroExtend(oW))
          .getRange(0, oW),
      sConst(0),
    );
    final colRowBase = mux(
      scOffGt1,
      (sConst(1) - (br[0] & bh4.lt(Const(2, width: 6))).zeroExtend(oW))
          .getRange(0, oW),
      sConst(0),
    );
    final scRRcalc = mux(
      scDir,
      (brS + colRowBase + scI).getRange(0, oW),
      (brS + scOff).getRange(0, oW),
    );
    final scCCcalc = mux(
      scDir,
      (bcS + scOff).getRange(0, oW),
      (bcS + rowColBase + scI).getRange(0, oW),
    );
    final scRR = mux(scIsBlk, scBlkR, scRRcalc);
    final scCC = mux(scIsBlk, scBlkC, scCCcalc);
    final scInside = insideOf(scRR, scCC);
    final scNb = miBsOf(scRR, scCC);
    final scN4w = miWideOf(scNb);
    final scN4h = miHighOf(scNb);
    // len
    final scBdim = mux(scDir, bh4, bw4);
    final scNdim = mux(scDir, scN4h, scN4w);
    final scUseStep16 = scBdim.gte(Const(16, width: 6));
    var scLen0 = mux(scBdim.lt(scNdim), scBdim, scNdim);
    final scLen = mux(
      scUseStep16,
      mux(scLen0.lt(Const(4, width: 6)), Const(4, width: 6), scLen0),
      mux(
        scOffGt1,
        mux(scLen0.lt(Const(2, width: 6)), Const(2, width: 6), scLen0),
        scLen0,
      ),
    );
    // weight + proc
    final scMaxAbs = mux(scDir, maxCol, maxRow);
    final scWeightEligible =
        scBdim.gte(Const(2, width: 6)) & scBdim.lte(scNdim);
    // inc = -max + off + 1
    final scInc0 = ((sConst(0) - scMaxAbs).getRange(0, oW) + scOff + sConst(1))
        .getRange(0, oW);
    final scOtherDim = mux(scDir, scN4w, scN4h); // ch for row, cw for col
    final scInc = mux(
      scOtherDim.zeroExtend(oW).lt(scInc0),
      scOtherDim.zeroExtend(oW),
      scInc0,
    );
    final scWeight = mux(
      scWeightEligible,
      mux(scInc.lt(Const(2, width: oW)), Const(2, width: oW), scInc),
      Const(2, width: oW),
    );
    final scProc = (scInc - scOff - sConst(1)).getRange(0, oW);
    // candidate mv/match from neighbour
    final scNbInter = gridRd(miInter, scRR, scCC, 1);
    final scNbRef0 = gridRd(miRef0, scRR, scCC, 3);
    final scNbMode = gridRd(miMode, scRR, scCC, 5);
    final scNbMvR = gridRd(miMvR, scRR, scCC, 16);
    final scNbMvC = gridRd(miMvC, scRR, scCC, 16);

    // dedup search over stack for (acR,acC)
    Logic foundFlag = Const(0);
    Logic foundIdx = Const(0, width: 4);
    for (var i = 7; i >= 0; i--) {
      final inRange = Const(i, width: 4).lt(fmCount);
      final match = inRange & fmStackR[i].eq(acR) & fmStackC[i].eq(acC);
      foundFlag = mux(match, Const(1), foundFlag);
      foundIdx = mux(match, Const(i, width: 4), foundIdx);
    }

    // clamp bounds for current block
    final clBorder = Const(128, width: 20);
    final clW = (bw4.zeroExtend(20) * Const(32, width: 20)).getRange(
      0,
      20,
    ); // bw4*4*8
    final clH = (bh4.zeroExtend(20) * Const(32, width: 20)).getRange(0, 20);
    // minC = -(c*32) - clW - border, maxC = (16-c)*32 + border  (miCols=16)
    final cCol32 = (bc.zeroExtend(20) * Const(32, width: 20)).getRange(0, 20);
    final rRow32 = (br.zeroExtend(20) * Const(32, width: 20)).getRange(0, 20);
    final minCol = (Const(0, width: 20) - cCol32 - clW - clBorder).getRange(
      0,
      20,
    );
    final maxColV =
        (((Const(16, width: 20) - bc.zeroExtend(20)).getRange(0, 20) *
                        Const(32, width: 20))
                    .getRange(0, 20) +
                clBorder)
            .getRange(0, 20);
    final minRow = (Const(0, width: 20) - rRow32 - clH - clBorder).getRange(
      0,
      20,
    );
    final maxRowV =
        (((Const(16, width: 20) - br.zeroExtend(20)).getRange(0, 20) *
                        Const(32, width: 20))
                    .getRange(0, 20) +
                clBorder)
            .getRange(0, 20);
    Logic clampS(Logic v16, Logic lo20, Logic hi20) {
      final v = [v16[15].replicate(4), v16].concat(); // sign extend to 20
      final lt = (v - lo20).getRange(0, 20)[19];
      final gt = (hi20 - v).getRange(0, 20)[19];
      return mux(lt, lo20.getRange(0, 16), mux(gt, hi20.getRange(0, 16), v16));
    }

    // TMVP temporal-candidate scan (_addTemporalMvs), only when wired.
    // Builds the sample geometry, the tpl-grid lookup, the HarborMvProjection
    // re-projection (tplMv scaled by cur_off/tplRefOff), lowerMvPrecision, and
    // the three temporal FSM states (dispatch / sample / add). gmv is (0,0)
    // (global motion disabled for the TMVP repro), so the globalmv trigger is
    // |proj| >= 16 per component.
    final tmvpItems = <CaseItem>[];
    Logic tGlobalMvBit = Const(0); // folded into mode_context at sFmvModeCtx
    if (enableTmvp) {
      // sample offset -> absolute mi position (SW add_tpl_ref_mv pos + is_inside).
      final tPosRow = mux(
        br[0],
        tBlkRow,
        (tBlkRow + sConst(1)).getRange(0, oW),
      );
      final tPosCol = mux(
        bc[0],
        tBlkCol,
        (tBlkCol + sConst(1)).getRange(0, oW),
      );
      final tAbsRow = (brS + tPosRow).getRange(0, oW);
      final tAbsCol = (bcS + tPosCol).getRange(0, oW);
      final tInside = insideOf(tAbsRow, tAbsCol);
      // when inside, abs in [0,16) so tr,tc = abs>>1 in [0,8).
      final tr = tAbsRow.getRange(1, 4);
      final tc = tAbsCol.getRange(1, 4);
      final tIdx =
          ((tr.zeroExtend(6) * Const(_tplDim, width: 6)).getRange(0, 6) +
                  tc.zeroExtend(6))
              .getRange(0, 6);
      Logic tplSel(Logic bus, int w) {
        Logic v = bus.getRange(0, w);
        for (var i = 1; i < _tplN; i++) {
          v = mux(
            tIdx.eq(Const(i, width: 6)),
            bus.getRange(i * w, i * w + w),
            v,
          );
        }
        return v;
      }

      final tValid = tplSel(input('tpl_valid'), 1);
      final tMvRow = tplSel(input('tpl_mvrow'), 16);
      final tMvCol = tplSel(input('tpl_mvcol'), 16);
      final tRefOff = tplSel(input('tpl_refoff'), 6);
      final tHit = tInside & tValid;
      // cur_off[ref0] (get_relative_dist(cur, refOrder[ref0])).
      final curOffBus = input('cur_off');
      Logic curOff = curOffBus.getRange(0, 8);
      for (var ref = 2; ref <= 7; ref++) {
        curOff = mux(
          ref0R.eq(Const(ref, width: 3)),
          curOffBus.getRange((ref - 1) * 8, (ref - 1) * 8 + 8),
          curOff,
        );
      }
      // projection (shared kernel).
      final tproj = HarborMvProjection(name: 'tmvp_proj');
      tproj.input('mv_row').srcConnection! <= tMvRow;
      tproj.input('mv_col').srcConnection! <= tMvCol;
      tproj.input('num').srcConnection! <= curOff;
      tproj.input('den').srcConnection! <= tRefOff;
      // lower_mv_precision.
      Logic lowerPrec(Logic v) {
        final odd = v[0];
        final adjHp = mux(
          ~v[15],
          (v - Const(1, width: 16)).getRange(0, 16),
          (v + Const(1, width: 16)).getRange(0, 16),
        );
        final hpRes = mux(odd, adjHp, v);
        final neg = v[15];
        final mag = mux(neg, (~v + Const(1, width: 16)).getRange(0, 16), v);
        final aint =
            (mag + Const(3, width: 16)).getRange(0, 16) &
            Const((~7) & 0xFFFF, width: 16);
        final intRes = mux(
          neg,
          (~aint + Const(1, width: 16)).getRange(0, 16),
          aint,
        );
        return mux(forceInt, intRes, mux(allowHp, v, hpRes));
      }

      final tPRow = lowerPrec(tproj.output('proj_row'));
      final tPCol = lowerPrec(tproj.output('proj_col'));
      Logic absGe16(Logic v) {
        final neg = v[15];
        final mag = mux(neg, (~v + Const(1, width: 16)).getRange(0, 16), v);
        return mag.gte(Const(16, width: 16));
      }

      // globalmv trigger: |proj - gmv| >= 16 per component (SW _addTplRefMv uses
      // the lowered block ref0 global MV, not (0,0)).
      final lgmvR = lowerPrec(gmv0R);
      final lgmvC = lowerPrec(gmv0C);
      final tGmvFar =
          absGe16((tPRow - lgmvR).getRange(0, 16)) |
          absGe16((tPCol - lgmvC).getRange(0, 16));

      // primary grid params + extended-sample geometry.
      Logic max6(Logic a, int b) =>
          mux(a.gt(Const(b, width: 6)), a, Const(b, width: 6));
      final blkRowEnd = mux(
        bh4.lt(Const(16, width: 6)),
        bh4,
        Const(16, width: 6),
      );
      final blkColEnd = mux(
        bw4.lt(Const(16, width: 6)),
        bw4,
        Const(16, width: 6),
      );
      final stepH = mux(bh4.gte(Const(16, width: 6)), sConst(4), sConst(2));
      final stepW = mux(bw4.gte(Const(16, width: 6)), sConst(4), sConst(2));
      final allowExt =
          bh4.gte(Const(2, width: 6)) &
          bh4.lt(Const(16, width: 6)) &
          bw4.gte(Const(2, width: 6)) &
          bw4.lt(Const(16, width: 6));
      final voffset = max6(bh4, 2);
      final hoffset = max6(bw4, 2);
      // extended sample [voffset,-2],[voffset,hoffset],[voffset-2,hoffset].
      final extRow = mux(
        tExtIdx.eq(Const(2, width: 2)),
        (sx(voffset) - sConst(2)).getRange(0, oW),
        sx(voffset),
      );
      final extCol = mux(
        tExtIdx.eq(Const(0, width: 2)),
        sConst(-2),
        sx(hoffset),
      );
      // checkSbBorder for the extended offset in (tBlkRow,tBlkCol).
      final sbRow = (brS + tBlkRow).getRange(0, oW);
      final sbCol = (bcS + tBlkCol).getRange(0, oW);
      final borderOk =
          ~sbRow[oW - 1] &
          sbRow.lt(Const(16, width: oW)) &
          ~sbCol[oW - 1] &
          sbCol.lt(Const(16, width: oW));

      tGlobalMvBit = fmGlobalMv;

      // Advance helpers for the primary grid (row-major, step stepH/stepW).
      final nextCol = (tBlkCol + stepW).getRange(0, oW);
      final primaryLastCol = ~nextCol.lt(blkColEnd.zeroExtend(oW)); // >= end
      final nextRow = (tBlkRow + stepH).getRange(0, oW);
      final primaryDone =
          primaryLastCol & ~nextRow.lt(blkRowEnd.zeroExtend(oW));

      // availability of the (0,0) sample: freshly computed when the current
      // (last) primary sample IS (0,0) (single-sample blocks), else the value
      // registered when (0,0) was processed earlier.
      final effAvail = mux(tZeroReg, tHitReg, tAvail);
      List<Conditional> gotoExtOrTl() => [
        // primary done: if avail==0 set globalmv, then extended or top-left.
        If(~effAvail, then: [fmGlobalMv < Const(1)]),
        If(
          allowExt,
          then: [
            tPhase < Const(1),
            tExtIdx < Const(0, width: 2),
            st < Const(sTmvpDisp, width: stW),
          ],
          orElse: [st < Const(sFmvTL, width: stW)],
        ),
      ];

      tmvpItems.addAll([
        CaseItem(Const(sTmvpDisp, width: stW), [
          If(
            ~tPhase,
            then: [
              // primary sample at (tBlkRow,tBlkCol) -> attempt.
              st < Const(sTmvpSample, width: stW),
            ],
            orElse: [
              // extended: load offset by tExtIdx, gate on checkSbBorder.
              If(
                tExtIdx.lt(Const(3, width: 2)),
                then: [
                  tBlkRow < extRow,
                  tBlkCol < extCol,
                  st < Const(sTmvpSample, width: stW),
                ],
                orElse: [st < Const(sFmvTL, width: stW)],
              ),
            ],
          ),
        ]),
        CaseItem(Const(sTmvpSample, width: stW), [
          // For extended samples, skip when checkSbBorder fails.
          If(
            tPhase & ~borderOk,
            then: [
              tExtIdx < (tExtIdx + Const(1, width: 2)).getRange(0, 2),
              st < Const(sTmvpDisp, width: stW),
            ],
            orElse: [
              // register the projected candidate + its status for sTmvpAdd.
              acR < tPRow,
              acC < tPCol,
              tHitReg < tHit,
              tGmvReg < (tHit & tGmvFar),
              tZeroReg <
                  (~tPhase & tBlkRow.eq(sConst(0)) & tBlkCol.eq(sConst(0))),
              st < Const(sTmvpAdd, width: stW),
            ],
          ),
        ]),
        CaseItem(Const(sTmvpAdd, width: stW), [
          // dedup + weight(+2)/push (like sScanAdd, weight 2, no match counts).
          If(
            tHitReg,
            then: [
              If(
                foundFlag,
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      foundIdx.eq(Const(i, width: 4)),
                      then: [
                        fmStackW[i] <
                            (fmStackW[i] + Const(2, width: 16)).getRange(0, 16),
                      ],
                    ),
                ],
                orElse: [
                  If(
                    fmCount.lt(Const(8, width: 4)),
                    then: [
                      for (var i = 0; i < 8; i++)
                        If(
                          fmCount.eq(Const(i, width: 4)),
                          then: [
                            fmStackR[i] < acR,
                            fmStackC[i] < acC,
                            fmStackW[i] < Const(2, width: 16),
                          ],
                        ),
                      fmCount < (fmCount + Const(1, width: 4)),
                    ],
                  ),
                ],
              ),
            ],
          ),
          // (0,0) sample: availability + globalmv trigger.
          If(
            tZeroReg,
            then: [
              tAvail < tHitReg,
              If(tGmvReg, then: [fmGlobalMv < Const(1)]),
            ],
          ),
          // advance to the next sample.
          If(
            ~tPhase,
            then: [
              If(
                primaryDone,
                then: gotoExtOrTl(),
                orElse: [
                  If(
                    primaryLastCol,
                    then: [
                      tBlkCol < Const(0, width: oW),
                      tBlkRow < nextRow,
                    ],
                    orElse: [tBlkCol < nextCol],
                  ),
                  st < Const(sTmvpDisp, width: stW),
                ],
              ),
            ],
            orElse: [
              tExtIdx < (tExtIdx + Const(1, width: 2)).getRange(0, 2),
              st < Const(sTmvpDisp, width: stW),
            ],
          ),
        ]),
      ]);
    }
    // residual coeff-decode combinational geometry + context (generic)
    // Supported tx sizes: square TX_4X4/8X8/16X16 (0/1/2) + the small rectangular
    // TX_4X8/8X4/8X16/16X8/4X16/16X4 (5/6/7/8/13/14). Buffers group by bhl
    // (height-log2): {4x4,8x4,16x4}=2, {8x8,4x8,16x8}=3, {16x16,8x16,4x16}=4.
    Logic curIs(int v) => curTxSize.eq(Const(v, width: 5));
    // txsize entropy ctx + geometry for the current txb.
    final txsCtx = rom(_txsCtxOf, curTxSize, 3);
    // VERT (mrow) scan position: ((c & (W-1))<<bhl) | (c>>log2W), per size.
    // (w, bhl, log2w) per size.
    const _vertParm = {
      0: [4, 2, 2],
      1: [8, 3, 3],
      2: [16, 4, 4],
      3: [32, 5, 5],
      5: [4, 3, 2],
      6: [8, 2, 3],
      7: [8, 4, 3],
      8: [16, 3, 4],
      13: [4, 4, 2],
      14: [16, 2, 4],
      9: [16, 5, 4],
      15: [8, 5, 3],
    };
    const _scanOfSz = {
      0: _scan4,
      1: _scan8,
      2: _scan16,
      3: _scan32,
      5: _scan4x8,
      6: _scan8x4,
      7: _scan8x16,
      8: _scan16x8,
      13: _scan4x16,
      14: _scan16x4,
      9: _scan16x32,
      15: _scan8x32,
    };
    // Raster position width: TX_32X32 (N=1024) reaches position 1023 (11 bits),
    // the smaller sizes stay <256 but share the mux so all are widened.
    const posW = 11;
    Logic vertOf(List<int> p) =>
        (((cIdx & Const(p[0] - 1, width: 8)) << p[1]) |
                (cIdx >> Const(p[2], width: 8)))
            .getRange(0, 8)
            .zeroExtend(posW);
    // Mux VERT / 2D scan over only the instantiated sizes.
    Logic muxOverSizes(Logic Function(int) f) {
      final order = txCoeffSizes;
      Logic v = f(order.last);
      for (var k = order.length - 2; k >= 0; k--) {
        v = mux(curIs(order[k]), f(order[k]), v);
      }
      return v;
    }

    final posVert = muxOverSizes((s) => vertOf(_vertParm[s]!));
    final posHorz = cIdx.zeroExtend(posW);
    final pos2d = muxOverSizes((s) => rom(_scanOfSz[s]!, cIdx, posW));
    final curPos = mux(
      txClassReg.eq(Const(2, width: 2)),
      posVert,
      mux(txClassReg.eq(Const(1, width: 2)), posHorz, pos2d),
    );

    // Per-size coeff-context engines, outputs muxed by curTxSize. Only the
    // instantiated txCoeffSizes are built (each is re-evaluated on every level
    // write, so a lean set keeps the simulation tractable). Each size at a given
    // bhl shares that bhl's levels buffer (a prefix slice).
    final ccBySz = <int, HarborCoeffContext>{};
    for (final sz in txCoeffSizes) {
      final cc = HarborCoeffContext(txSize: sz, memBacked: true, name: 'cc$sz');
      addSubModule(cc);
      ccBySz[sz] = cc;
    }
    // Read-side control wiring (coeff_idx/scan_idx/tx_class + clk/reset). The
    // write port (wr_en/wr_idx/wr_val/clear) is driven below, once the write
    // datapath (isEobMinus1/levelReg/sym/state) is in scope.
    void wireCc(HarborCoeffContext cc) {
      cc.input('clk').srcConnection! <= clk;
      cc.input('reset').srcConnection! <= reset;
      cc.input('coeff_idx').srcConnection! <=
          curPos.getRange(0, cc.input('coeff_idx').width);
      final sw = cc.input('scan_idx').width;
      cc.input('scan_idx').srcConnection! <=
          (sw <= 8 ? cIdx.getRange(0, sw) : cIdx.zeroExtend(sw));
      cc.input('tx_class').srcConnection! <= txClassReg;
    }

    for (final sz in txCoeffSizes) {
      wireCc(ccBySz[sz]!);
    }
    Logic ccOut(String p) {
      final order = txCoeffSizes;
      Logic v = ccBySz[order.last]!.output(p);
      for (var k = order.length - 2; k >= 0; k--) {
        v = mux(curIs(order[k]), ccBySz[order[k]]!.output(p), v);
      }
      return v;
    }

    final baseEobCtx = ccOut('base_eob_ctx');
    final base2dCtx = ccOut('base_ctx_2d');
    final baseGenCtx = ccOut('base_ctx_gen');
    final brEobCtx = ccOut('br_ctx_eob');
    final brGenCtx = ccOut('br_ctx_gen');
    final br2dCtx = ccOut('br_ctx_2d');

    final isEobMinus1 = cIdx.eq((eobReg - Const(1, width: 11)).getRange(0, 8));
    final isC0c = cIdx.eq(Const(0, width: 8));
    final is2d = txClassReg.eq(Const(0, width: 2));
    final txsBase = (txsCtx.zeroExtend(ecw)).getRange(0, ecw);
    // plane-type select for the coeff CDF banks: chroma (curPlane != 0) uses the
    // appended plane-type-1 banks, luma uses plane-type-0.
    final pC = curPlane.or();
    Logic pmux(int b0, int b1) =>
        mux<Logic>(pC, Const(b1, width: ecw), Const(b0, width: ecw));
    // coeff_base CDF context flat index (base_eob for eob-1, else general/2d).
    final baseSubCtx = mux(
      isEobMinus1,
      baseEobCtx.zeroExtend(6),
      mux(is2d & ~isC0c, base2dCtx, baseGenCtx),
    );
    // TX_32X32 (txsCtx 3) reads its own appended luma banks (cBaseEob3/cBase3/
    // cBr3), a flat slice indexed only by the sub-ctx (no txsBase stride).
    final baseFlat = mux(
      curIs(3),
      mux(
        isEobMinus1,
        (Const(cBaseEob3, width: ecw) + baseEobCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        ),
        (Const(cBase3, width: ecw) + baseSubCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        ),
      ),
      mux(
        isEobMinus1,
        (pmux(cBaseEob, cBaseEob1) +
                (txsBase * Const(4, width: ecw)).getRange(0, ecw) +
                baseEobCtx.zeroExtend(ecw))
            .getRange(0, ecw),
        (pmux(cBase, cBase1) +
                (txsBase * Const(42, width: ecw)).getRange(0, ecw) +
                baseSubCtx.zeroExtend(ecw))
            .getRange(0, ecw),
      ),
    );
    final brSubCtx = mux(
      isEobMinus1,
      brEobCtx.zeroExtend(5),
      mux(is2d & ~isC0c, br2dCtx, brGenCtx),
    );
    final brFlat = mux(
      curIs(3),
      (Const(cBr3, width: ecw) + brSubCtx.zeroExtend(ecw)).getRange(0, ecw),
      (pmux(cBr, cBr1) +
              (txsBase * Const(21, width: ecw)).getRange(0, ecw) +
              brSubCtx.zeroExtend(ecw))
          .getRange(0, ecw),
    );
    // phase-B: current level at the forward scan position = the active cc's
    // cur_level read (store[padded(coeff_idx)], template offset 0).
    final pbCur = ccOut('cur_level');
    // eob_extra CDF context (txsCtx*9 + (eobPt-3)) and eob-group start.
    final eobExtraCtx = mux(
      curIs(3),
      (Const(cEobExtra3, width: ecw) +
              (eobPtReg - Const(3, width: 4)).zeroExtend(ecw))
          .getRange(0, ecw),
      (pmux(cEobExtra, cEobExtra1) +
              (txsBase * Const(9, width: ecw)).getRange(0, ecw) +
              (eobPtReg - Const(3, width: 4)).zeroExtend(ecw))
          .getRange(0, ecw),
    );
    final groupStart = rom(_eobGroupStart, eobPtReg, 11);
    final offBits = rom(_eobOffsetBits, eobPtReg, 4);

    // level-memory write port
    // The old writeLevelGen wrote levels[padded(curPos)] as a per-cell register
    // assignment inside the FSM (at rBaseCap when the base level <= 2, or at
    // rBrCap on the terminating coeff_br). Replicate exactly which cell/value
    // is written each cycle as a combinational request. The active cc captures
    // it on the same clock edge, so the buffer contents are byte-identical.
    final wLvlBaseVal = mux(
      isEobMinus1,
      (sym.zeroExtend(8) + Const(1, width: 8)).getRange(0, 8),
      sym.zeroExtend(8),
    );
    final wLvlBrVal = (levelReg + sym.zeroExtend(8)).getRange(0, 8);
    final wLvlAtBase =
        st.eq(Const(rBaseCap, width: stW)) &
        ~wLvlBaseVal.gt(Const(2, width: 8));
    final wLvlAtBr =
        st.eq(Const(rBrCap, width: stW)) &
        (sym.lt(Const(3, width: ec.symWidth)) | brIdxR.eq(Const(3, width: 3)));
    final lvlWrEn = wLvlAtBase | wLvlAtBr;
    final lvlWrVal = mux(
      st.eq(Const(rBaseCap, width: stW)),
      wLvlBaseVal,
      wLvlBrVal,
    );
    // Per-txb clear: entering a luma leaf (rLeafSetup), the chroma U txb
    // (rLeafNext once all luma leaves are done), or the chroma V txb (rCEcWrite
    // advancing U->V). Matches the old per-site buffer-zeroing exactly.
    final lvlClear =
        st.eq(Const(rLeafSetup, width: stW)) |
        (st.eq(Const(rLeafNext, width: stW)) & vtCur.gte(vtN)) |
        (st.eq(Const(rCEcWrite, width: stW)) & curPlane.eq(Const(1, width: 2)));
    for (final sz in txCoeffSizes) {
      final cc = ccBySz[sz]!;
      cc.input('clear').srcConnection! <= lvlClear;
      cc.input('wr_en').srcConnection! <= lvlWrEn & curIs(sz);
      cc.input('wr_idx').srcConnection! <=
          curPos.getRange(0, cc.input('wr_idx').width);
      cc.input('wr_val').srcConnection! <= lvlWrVal;
    }

    // getTxbCtx: skipCtx + dcSignCtx from the per-plane EC arrays.
    // tx units for the current txb.
    final txwU = rom(_txWideUnit, curTxSize, 5);
    final txhU = rom(_txHighUnit, curTxSize, 5);
    // read the active plane's above/left EC. Sum OR (skip) and dc-sign.
    List<Logic> ecAbove(int plane) =>
        plane == 0 ? aboveEC0 : (plane == 1 ? aboveEC1 : aboveEC2);
    List<Logic> ecLeft(int plane) =>
        plane == 0 ? leftEC0 : (plane == 1 ? leftEC1 : leftEC2);
    // luma skipCtx: 0 if block==txb, else _txbSkipCtxTbl[top][left].
    Logic ecReadOrTop(List<Logic> arr, Logic off, Logic cnt) {
      // OR of arr[off .. off+cnt) & 63, clamped to 4.
      Logic acc = Const(0, width: 8);
      for (var k = 0; k < arr.length; k++) {
        final inR =
            (Const(k, width: 6).gte(off.zeroExtend(6))) &
            (Const(
              k,
              width: 6,
            ).lt((off.zeroExtend(6) + cnt.zeroExtend(6)).getRange(0, 6)));
        acc = acc | mux(inR, arr[k], Const(0, width: 8));
      }
      final m = (acc & Const(63, width: 8));
      return mux(
        m.gt(Const(4, width: 8)),
        Const(4, width: 8),
        m,
      ).getRange(0, 3);
    }

    Logic ecReadNz(List<Logic> arr, Logic off, Logic cnt) {
      Logic any = Const(0);
      for (var k = 0; k < arr.length; k++) {
        final inR =
            (Const(k, width: 6).gte(off.zeroExtend(6))) &
            (Const(
              k,
              width: 6,
            ).lt((off.zeroExtend(6) + cnt.zeroExtend(6)).getRange(0, 6)));
        any = any | (inR & arr[k].or());
      }
      return any;
    }

    // signed dc-sign sum: for each in-range entry, (val>>6): 1->-1, 2->+1.
    Logic ecDcSum(List<Logic> arr, Logic off, Logic cnt) {
      Logic sum = Const(0, width: 8); // biased later
      for (var k = 0; k < arr.length; k++) {
        final inR =
            (Const(k, width: 6).gte(off.zeroExtend(6))) &
            (Const(
              k,
              width: 6,
            ).lt((off.zeroExtend(6) + cnt.zeroExtend(6)).getRange(0, 6)));
        final s = (arr[k] >> Const(6, width: 8)) & Const(3, width: 8);
        final delta = mux(
          s.eq(Const(1, width: 8)),
          Const(0xff, width: 8),
          mux<Logic>(
            s.eq(Const(2, width: 8)),
            Const(1, width: 8),
            Const(0, width: 8),
          ),
        );
        sum = (sum + mux(inR, delta, Const(0, width: 8))).getRange(0, 8);
      }
      return sum; // two's-complement small signed
    }

    // block == txb check: planeBsize == txsizeToBsize[txSize] (luma).
    final blockEqTx = bbs.eq(rom(_txToBsize, curTxSize, 5));
    Logic skipCtxFor(int plane) {
      final aOff = curAOff, lOff = curLOff;
      if (plane == 0) {
        final top = ecReadOrTop(aboveEC0, aOff, txwU);
        final left = ecReadOrTop(leftEC0, lOff, txhU);
        final tbl = _txbSkipCtxTbl;
        Logic v = Const(0, width: 4);
        for (var t = 0; t < 5; t++) {
          for (var l = 0; l < 5; l++) {
            v = mux(
              top.eq(Const(t, width: 3)) & left.eq(Const(l, width: 3)),
              Const(tbl[t * 5 + l], width: 4),
              v,
            );
          }
        }
        return mux(blockEqTx, Const(0, width: 4), v);
      } else {
        final a = ecReadNz(ecAbove(plane), aOff, txwU);
        final l = ecReadNz(ecLeft(plane), lOff, txhU);
        final off = rom(_chromaSkipOff420, bbs, 4);
        return (a.zeroExtend(4) + l.zeroExtend(4) + off.zeroExtend(4)).getRange(
          0,
          4,
        );
      }
    }

    Logic dcSignCtxFor(int plane) {
      final s =
          (ecDcSum(ecAbove(plane), curAOff, txwU) +
                  ecDcSum(ecLeft(plane), curLOff, txhU))
              .getRange(0, 8);
      // s is small signed, dcSignCtx = s<0?1 : s==0?0 : 2.
      final neg = s[7];
      final zero = s.eq(Const(0, width: 8));
      return mux(
        zero,
        Const(0, width: 2),
        mux<Logic>(neg, Const(1, width: 2), Const(2, width: 2)),
      );
    }

    final lumaSkipCtx = skipCtxFor(0);
    final lumaDcCtx = dcSignCtxFor(0);
    // chroma skip/dc contexts read the ACTIVE plane's EC arrays (U=plane1 EC1,
    // V=plane2 EC2), selected at runtime by curPlane.
    final chromaSkipCtx = mux(
      curPlane.eq(Const(2, width: 2)),
      skipCtxFor(2),
      skipCtxFor(1),
    );
    final chromaDcCtx = mux(
      curPlane.eq(Const(2, width: 2)),
      dcSignCtxFor(2),
      dcSignCtxFor(1),
    );
    // EC-write value: culLevel (bits0..5) | dc-sign (bit6=neg, add 2<<6 pos).
    final ecWriteVal =
        (culLevelReg.zeroExtend(8) |
                mux(
                  dcValNeg,
                  Const(1 << 6, width: 8),
                  mux<Logic>(
                    dcValPos,
                    Const(2 << 6, width: 8),
                    Const(0, width: 8),
                  ),
                ))
            .getRange(0, 8);
    List<Conditional> setEntropyCtx(int plane, Logic aOff, Logic lOff) {
      final a = ecAbove(plane), l = ecLeft(plane);
      return [
        for (var k = 0; k < a.length; k++)
          If(
            (Const(k, width: 6).gte(aOff.zeroExtend(6))) &
                (Const(
                  k,
                  width: 6,
                ).lt((aOff.zeroExtend(6) + txwU.zeroExtend(6)).getRange(0, 6))),
            then: [a[k] < ecWriteVal],
          ),
        for (var k = 0; k < l.length; k++)
          If(
            (Const(k, width: 6).gte(lOff.zeroExtend(6))) &
                (Const(
                  k,
                  width: 6,
                ).lt((lOff.zeroExtend(6) + txhU.zeroExtend(6)).getRange(0, 6))),
            then: [l[k] < ecWriteVal],
          ),
      ];
    }

    // generic residual CDF context indices.
    final eobMS = rom(_eobMSOf, curTxSize, 4);
    final ySkipCtxIdx = mux(
      curIs(3),
      (Const(cTxbSkip3, width: ecw) + lumaSkipCtx.zeroExtend(ecw)).getRange(
        0,
        ecw,
      ),
      (Const(cTxbSkip, width: ecw) +
              (txsBase * Const(13, width: ecw)).getRange(0, ecw) +
              lumaSkipCtx.zeroExtend(ecw))
          .getRange(0, ecw),
    );
    // inter ext-tx CDF bank. get_ext_tx_set keys the SET on tx_size_sqr_up: any
    // tx whose enclosing square is TX_32X32 uses the 2-sym DCT_IDTX set (set 3),
    // whose CDF is interExtTxCdf[3][tx_size_sqr], so 8x32/32x8 (sqr TX_8X8) use
    // [3][1] (cInterTx32Sq1), 16x32/32x16 (sqr TX_16X16) use [3][2]
    // (cInterTx32Sq2), and 32x32 (sqr TX_32X32) uses [3][3] (cInterTx32). The
    // non-32-up sizes select by tx_size_sqr: 0->set5 TX_4X4(16), 1->set5
    // TX_8X8(16), 2->set4 TX_16X16(12).
    final sqrTx = rom(_txSqrMap, curTxSize, 3);
    final sqrUpIs32 = rom(_txSqrUp, curTxSize, 3).eq(Const(3, width: 3));
    final tx32Ctx = mux(
      sqrTx.eq(Const(1, width: 3)),
      Const(cInterTx32Sq1, width: ecw),
      mux<Logic>(
        sqrTx.eq(Const(2, width: 3)),
        Const(cInterTx32Sq2, width: ecw),
        Const(cInterTx32, width: ecw),
      ),
    );
    final txTypeCtxIdx = mux(
      sqrUpIs32,
      tx32Ctx,
      mux(
        sqrTx.eq(Const(0, width: 3)),
        Const(cInterTx4, width: ecw),
        mux<Logic>(
          sqrTx.eq(Const(1, width: 3)),
          Const(cInterTx8, width: ecw),
          Const(cInterTx16, width: ecw),
        ),
      ),
    );
    // resolved inter tx_type + class from the decoded ext-tx symbol: sqr_up
    // TX_32X32 -> set 3 (2-sym), TX_16X16 -> set4 (12-sym), else set5 (16-sym).
    final rTxTypeSym = mux(
      sqrUpIs32,
      rom(_extTxInv1, sym.getRange(0, 4), 5),
      mux(
        curTxSize.eq(Const(2, width: 5)),
        rom(_extTxInv4, sym.getRange(0, 4), 5),
        rom(_extTxInv5, sym.getRange(0, 4), 5),
      ),
    );
    final rTxClassSym = rom(_txClass16, rTxTypeSym, 2);
    final eobPtCtxIdx =
        (pmux(cEobPt, cEobPt1) +
                (eobMS.zeroExtend(ecw) * Const(2, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                mux<Logic>(is2d, Const(0, width: ecw), Const(1, width: ecw)))
            .getRange(0, ecw);
    final chromaUvTx = rom(_uvTx420, bbs, 5);
    final chromaTxsCtx = rom(_txsCtxOf, chromaUvTx, 3);
    final chromaSkipCtxIdx =
        (Const(cTxbSkip, width: ecw) +
                (chromaTxsCtx.zeroExtend(ecw) * Const(13, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                chromaSkipCtx.zeroExtend(ecw))
            .getRange(0, ecw);
    // dc-sign CDF: luma uses plane-0 dc ctx, chroma uses the active plane's.
    final dcCtxCur = mux(pC, chromaDcCtx, lumaDcCtx);
    final dcSignCtxIdx = (pmux(cDcSign, cDcSign1) + dcCtxCur.zeroExtend(ecw))
        .getRange(0, ecw);

    // intra-block (in inter frame) mode-info contexts.
    // chroma_ref + cfl_allowed (4:2:0): chroma present unless a sub-8x8 half is
    // dropped. cfl needs the block <= 32x32 (bw4,bh4 <= 8 mi units).
    final chromaRef = (br[0] | ~bh4[0]) & (bc[0] | ~bw4[0]);
    final cflAllowed =
        chromaRef & bw4.lte(Const(8, width: 6)) & bh4.lte(Const(8, width: 6));
    final useAngle = bbs.gte(Const(3, width: 5)); // av1_use_angle_delta
    final yModeCtxIdx =
        (Const(cYMode, width: ecw) +
                rom(_sizeGroupLookup, bbs, 2).zeroExtend(ecw))
            .getRange(0, ecw);
    final uvModeCtxIdx =
        (Const(cUvMode, width: ecw) +
                (cflAllowed.zeroExtend(ecw) * Const(13, width: ecw)).getRange(
                  0,
                  ecw,
                ) +
                yModeReg.zeroExtend(ecw))
            .getRange(0, ecw);
    final angleYCtxIdx =
        (Const(cAngle, width: ecw) +
                (yModeReg - Const(1, width: 5)).zeroExtend(ecw))
            .getRange(0, ecw);
    final uvIntraMode = rom(_uv2y, uvModeReg, 5);
    final angleUvCtxIdx =
        (Const(cAngle, width: ecw) +
                (uvIntraMode - Const(1, width: 5)).zeroExtend(ecw))
            .getRange(0, ecw);

    // txfm_partition (var-tx) context for the current tree node.
    // above/left tx context (px), 64 at the tile edge, aboveS/leftS compare vs
    // the node tx width/height, category from the block max square tx.
    final nodeTxW = (rom(_txWideUnit, vtNodeTx, 5).zeroExtend(7) << 2).getRange(
      0,
      7,
    ); // *4 px
    final nodeTxH = (rom(_txHighUnit, vtNodeTx, 5).zeroExtend(7) << 2).getRange(
      0,
      7,
    );
    final atxV = mux(
      vtNodeR.eq(Const(0, width: 5)),
      Const(64, width: 7),
      arrRd(aboveTxfm, vtNodeC, 7),
    );
    final ltxV = mux(
      vtNodeC.eq(Const(0, width: 5)),
      Const(64, width: 7),
      arrRd(leftTxfm, vtNodeR, 7),
    );
    final aboveS = atxV.lt(nodeTxW);
    final leftS = ltxV.lt(nodeTxH);
    // block max square tx: blkDim = max(blockW,blockH), getSqrTxSize.
    final blkW = (miWideOf(bbs).zeroExtend(7) << 2).getRange(0, 7);
    final blkH = (miHighOf(bbs).zeroExtend(7) << 2).getRange(0, 7);
    final blkDim = mux(blkW.gt(blkH), blkW, blkH);
    final maxSqrTx = mux(
      blkDim.gte(Const(64, width: 7)),
      Const(4, width: 3),
      mux(
        blkDim.eq(Const(32, width: 7)),
        Const(3, width: 3),
        mux(
          blkDim.eq(Const(16, width: 7)),
          Const(2, width: 3),
          mux<Logic>(
            blkDim.eq(Const(8, width: 7)),
            Const(1, width: 3),
            Const(0, width: 3),
          ),
        ),
      ),
    );
    // category = ((sqrUp[nodeTx]!=maxSqrTx && maxSqrTx>1)?1:0) + (4-maxSqrTx)*2.
    final sqrUpNode = rom(_txSqrUp, vtNodeTx, 3);
    final catA = (~sqrUpNode.eq(maxSqrTx) & maxSqrTx.gt(Const(1, width: 3)));
    final category = mux(
      maxSqrTx.gte(Const(1, width: 3)),
      (catA.zeroExtend(5) +
              ((Const(4, width: 5) - maxSqrTx.zeroExtend(5)).getRange(0, 5) <<
                  1))
          .getRange(0, 5),
      Const(0, width: 5),
    );
    final txfmPartCtx =
        ((category * Const(3, width: 5)).getRange(0, 5) +
                aboveS.zeroExtend(5) +
                leftS.zeroExtend(5))
            .getRange(0, 5);
    final txfmPartCtxIdx =
        (Const(cTxfmPart, width: ecw) + txfmPartCtx.zeroExtend(ecw)).getRange(
          0,
          ecw,
        );

    // outputs
    output('res_valid') <= resValidReg;
    output('res_eob') <= resEobReg;
    output('res_txtype') <= resTxTypeReg;
    output('res_txsize') <= curTxSize.getRange(0, 3);
    output('done') <= st.eq(Const(sDone, width: stW));
    output('sym_count') <= symCnt;
    output('sym_valid') <= symValid;
    output('rng') <= ec.output('rng');
    output('block_valid') <= blockValid;
    output('blk_r') <= br;
    output('blk_c') <= bc;
    output('blk_bs') <= bbs;
    output('blk_mode') <= modeR;
    output('blk_ref0') <= ref0R;
    output('blk_mvrow') <= mvRowReg;
    output('blk_mvcol') <= mvColReg;
    output('blk_modectx') <= fmModeCtx;
    output('blk_count') <= fmCount;
    output('blk_ref1') <= ref1R;
    output('blk_mvrow1') <= mvRow1Reg;
    output('blk_mvcol1') <= mvCol1Reg;
    output('blk_comptype') <= compTypeReg;
    output('blk_skipmode') <= skipModeReg;
    output('blk_motionmode') <= motionModeReg;
    output('blk_interintra') <= iiReg;
    output('blk_iimode') <= iiModeReg;
    output('blk_iiwedge') <= iiWedgeReg;
    output('blk_iiwedgeidx') <= iiWedgeIdxReg;

    // combinational od_ec control
    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: ecw),
      ecCdf < Const(0, width: maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: stW), [
          ecLoad < Const(1),
          ecCtx < pli,
          ecCdf < cdfForCtx(pli),
          ecNsyms < nsymsForCtx(pli),
        ]),
        CaseItem(Const(sInit, width: stW), [ecInit < Const(1)]),
        CaseItem(Const(sPartDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < partCtxIdx,
        ]),
        CaseItem(Const(sSkipDec, width: stW), [
          ecDecode < Const(1),
          ecCtx <
              (Const(cSkip, width: ecw) + skipCtx.zeroExtend(ecw)).getRange(
                0,
                ecw,
              ),
        ]),
        // skip_mode / comp_mode reads are CONDITIONAL: only assert a decode when
        // the frame-level gate + comp-ref-allowed hold (else the state is a
        // 1-cycle pass-through to the next read, consuming no od_ec symbol).
        CaseItem(Const(sSkipModeDec, width: stW), [
          If(
            skipModePresent & compRefAllowed,
            then: [ecDecode < Const(1), ecCtx < skipModeCtxIdx],
          ),
        ]),
        CaseItem(Const(sCompModeDec, width: stW), [
          If(
            refModeSelect & compRefAllowed,
            then: [ecDecode < Const(1), ecCtx < compInterCtxIdx],
          ),
        ]),
        // explicit-compound decode contexts
        CaseItem(Const(sCompRefTypeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < compRefTypeCtxIdx,
        ]),
        CaseItem(Const(sCompRefDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < mux(crPhase.gte(Const(5, width: 3)), uniCtxIdx, crCtxIdx),
        ]),
        CaseItem(Const(sInterCompModeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < interCompModeCtxIdx,
        ]),
        CaseItem(Const(sCompDrlDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < drlCtxIdx,
        ]),
        CaseItem(Const(sCompTypeGrpDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < compGrpCtxIdx,
        ]),
        CaseItem(Const(sCompTypeSymDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < compoundTypeCtxIdx,
        ]),
        CaseItem(Const(sWedgeIdxDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < wedgeIdxCtxIdx,
        ]),
        // interintra decode dispatch (nsyms come from the per-ctx ROM).
        CaseItem(Const(sIIDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < iiCtxIdx,
        ]),
        CaseItem(Const(sIIModeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < iiModeCtxIdx,
        ]),
        CaseItem(Const(sIIWedgeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < iiWedgeCtxIdx,
        ]),
        CaseItem(Const(sIIWedgeIdxDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < wedgeIdxCtxIdx,
        ]),
        CaseItem(Const(sMaskTypeLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(sMaskTypeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cBypass, width: ecw),
        ]),
        CaseItem(Const(sWedgeSignLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(sWedgeSignDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cBypass, width: ecw),
        ]),
        CaseItem(Const(sIsInterDec, width: stW), [
          ecDecode < Const(1),
          ecCtx <
              (Const(cIsInter, width: ecw) + isInterCtx.zeroExtend(ecw))
                  .getRange(0, ecw),
        ]),
        CaseItem(Const(sSrDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < srCtxIdx,
        ]),
        CaseItem(Const(sModeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx <
              (Const(cNewMv, width: ecw) + newmvCtx.zeroExtend(ecw)).getRange(
                0,
                ecw,
              ),
        ]),
        CaseItem(Const(sZeroDec, width: stW), [
          ecDecode < Const(1),
          ecCtx <
              (Const(cZeroMv, width: ecw) + zeroCtx.zeroExtend(ecw)).getRange(
                0,
                ecw,
              ),
        ]),
        CaseItem(Const(sRefDec, width: stW), [
          ecDecode < Const(1),
          ecCtx <
              (Const(cRefMv, width: ecw) + refmvCtx.zeroExtend(ecw)).getRange(
                0,
                ecw,
              ),
        ]),
        CaseItem(Const(sDrlDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < drlCtxIdx,
        ]),
        CaseItem(Const(sJointDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cJoint, width: ecw),
        ]),
        CaseItem(Const(sSignDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < signCtx,
        ]),
        CaseItem(Const(sClassDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < classCtx,
        ]),
        CaseItem(Const(sClass0Dec, width: stW), [
          ecDecode < Const(1),
          ecCtx < class0Ctx,
        ]),
        CaseItem(Const(sBitsDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < bitsCtx,
        ]),
        CaseItem(Const(sFpDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < fpCtx,
        ]),
        CaseItem(Const(sHpDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < hpCtx,
        ]),
        // motion_mode: 2-value obmcCdf[bSize].
        CaseItem(Const(sMmDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < obmcCtxIdx,
        ]),
        // motion_mode: 3-value motionModeCdf[bSize].
        CaseItem(Const(sMmDec3, width: stW), [
          ecDecode < Const(1),
          ecCtx < motionModeCtxIdx,
        ]),
        // intra-block mode-info decode contexts
        CaseItem(Const(sIntraY, width: stW), [
          ecDecode < Const(1),
          ecCtx < yModeCtxIdx,
        ]),
        CaseItem(Const(sIntraAngleY, width: stW), [
          ecDecode < Const(1),
          ecCtx < angleYCtxIdx,
        ]),
        CaseItem(Const(sIntraUv, width: stW), [
          ecDecode < Const(1),
          ecCtx < uvModeCtxIdx,
        ]),
        CaseItem(Const(sIntraAngleUv, width: stW), [
          ecDecode < Const(1),
          ecCtx < angleUvCtxIdx,
        ]),
        // residual coeff decode contexts (generic by curTxSize/plane)
        CaseItem(Const(rYSkipDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < ySkipCtxIdx,
        ]),
        CaseItem(Const(rTxTypeDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < txTypeCtxIdx,
        ]),
        CaseItem(Const(rEobPtDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < eobPtCtxIdx,
        ]),
        CaseItem(Const(rExtraDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < eobExtraCtx,
        ]),
        CaseItem(Const(rBaseDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < baseFlat,
        ]),
        CaseItem(Const(rBrDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < brFlat,
        ]),
        CaseItem(Const(rPbSignDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < mux(isC0c, dcSignCtxIdx, Const(cBypass, width: ecw)),
        ]),
        CaseItem(Const(rCSkipDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < chromaSkipCtxIdx,
        ]),
        CaseItem(Const(rTxfmPartDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < txfmPartCtxIdx,
        ]),
        // bypass reloads (fixed [16384,0]) + their decodes.
        CaseItem(Const(rBypLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(rPbSignLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(rPbGolLeadLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(rPbGolReadLoad, width: stW), [
          ecLoad < Const(1),
          ecCtx < Const(cBypass, width: ecw),
          ecCdf < bypassCdf(),
          ecNsyms < Const(2, width: 5),
        ]),
        CaseItem(Const(rBypDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cBypass, width: ecw),
        ]),
        CaseItem(Const(rPbGolLeadDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cBypass, width: ecw),
        ]),
        CaseItem(Const(rPbGolReadDec, width: stW), [
          ecDecode < Const(1),
          ecCtx < Const(cBypass, width: ecw),
        ]),
      ]),
    ]);

    // scan invocation helper (Dart-generates the register writes).
    List<Conditional> startScan(
      int dir,
      Logic off,
      bool matchCol,
      int retSt, {
      bool isBlk = false,
      bool updProc = false,
      bool countNew = false,
      Logic? blkR,
      Logic? blkC,
    }) => [
      scDir < Const(dir),
      scOff < off,
      scMatchCol < Const(matchCol ? 1 : 0),
      scIsBlk < Const(isBlk ? 1 : 0),
      scUpdProc < Const(updProc ? 1 : 0),
      scCountNew < Const(countNew ? 1 : 0),
      if (blkR != null) scBlkR < blkR,
      if (blkC != null) scBlkC < blkC,
      scI < Const(0, width: oW),
      scEnd <
          (isBlk
              ? Const(1, width: oW)
              : mux(
                  (dir == 0 ? bw4 : bh4).lt(Const(16, width: 6)),
                  (dir == 0 ? bw4 : bh4).zeroExtend(oW),
                  Const(16, width: oW),
                )),
      scRet < Const(retSt, width: 8),
      st < Const(sScanStep, width: stW),
    ];

    // outer scan (idx 2..3). dir 0 row / 1 col. rowOffset/colOffset =
    // -(idx*2)+1+adj. Fires when |off|<=|max| && |off|>proc, else skip.
    List<Conditional> outerScan(
      int dir,
      int idx,
      Logic adj,
      Logic maxV,
      Logic proc,
      Logic nextOut,
    ) {
      final off = (sConst(-(idx * 2) + 1) + adj.zeroExtend(oW)).getRange(0, oW);
      final aoff = absO(off);
      final fires = aoff.lte(absO(maxV)) & aoff.gt(proc);
      return [
        outIdx < nextOut,
        If(
          fires,
          then: startScan(dir, off, dir == 1, sFmvOuter, updProc: true),
          orElse: [st < Const(sFmvOuter, width: stW)],
        ),
      ];
    }
    // startScan sets scRet=sFmvOuter so the scan returns and re-dispatches on
    // the advanced outIdx.

    // sequential FSM
    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: stW),
          cursor < Const(0, width: cursor.width),
          pli < Const(0, width: ecw),
          sp < Const(0, width: spW),
          // TMVP temporal-scan regs (driven here so they are never floating, the
          // temporal states only run when enableTmvp && use_ref_frame_mvs).
          tBlkRow < Const(0, width: oW),
          tBlkCol < Const(0, width: oW),
          tPhase < Const(0),
          tExtIdx < Const(0, width: 2),
          tAvail < Const(0),
          fmGlobalMv < Const(0),
          tHitReg < Const(0),
          tGmvReg < Const(0),
          tZeroReg < Const(0),
          symCnt < Const(0, width: 12),
          symValid < Const(0),
          blockValid < Const(0),
          isIntraReg < Const(0),
          yModeReg < Const(0, width: 5),
          uvModeReg < Const(0, width: 5),
          motionModeReg < Const(0, width: 2),
          iiReg < Const(0),
          iiModeReg < Const(0, width: 2),
          iiWedgeReg < Const(0),
          iiWedgeIdxReg < Const(0, width: 4),
          resValidReg < Const(0),
          skipReg < Const(0),
          compGrpReg < Const(0),
          crPhase < Const(0, width: 3),
          txClassReg < Const(0, width: 2),
          txTypeReg < Const(0, width: 5),
          blkLumaTxType < Const(0, width: 5),
          eobReg < Const(0, width: 11),
          eobPtReg < Const(0, width: 4),
          cIdx < Const(0, width: 8),
          levelReg < Const(0, width: 8),
          brIdxR < Const(0, width: 3),
          offBitsR < Const(0, width: 4),
          eobExtraR < Const(0, width: 11),
          bypIdxR < Const(0, width: 4),
          csignReg < Const(0),
          pbLevelReg < Const(0, width: 21),
          golLeadR < Const(0, width: 6),
          golXR < Const(0, width: 21),
          golCntR < Const(0, width: 6),
          resEobReg < Const(0, width: 11),
          resTxTypeReg < Const(0, width: 5),
          curTxSize < Const(0, width: 5),
          curPlane < Const(0, width: 2),
          curAOff < Const(0, width: 5),
          curLOff < Const(0, width: 5),
          culLevelReg < Const(0, width: 7),
          dcValNeg < Const(0),
          dcValPos < Const(0),
          vtN < Const(0, width: 3),
          vtCur < Const(0, width: 3),
          vtSplitR < Const(0),
          vtNodeR < Const(0, width: 5),
          vtNodeC < Const(0, width: 5),
          vtNodeTx < Const(0, width: 5),
          resPlane < Const(0, width: 2),
          for (var i = 0; i < 4; i++) ...[
            vtSz[i] < Const(0, width: 5),
            vtIdy[i] < Const(0, width: 5),
            vtIdx[i] < Const(0, width: 5),
          ],
          // level buffers are cleared inside each cc via cc.reset (driven here).
          for (var i = 0; i < 16; i++) ...[
            aboveEC0[i] < Const(0, width: 8),
            leftEC0[i] < Const(0, width: 8),
            aboveTxfm[i] < Const(64, width: 7),
            leftTxfm[i] < Const(64, width: 7),
          ],
          for (var i = 0; i < 8; i++) ...[
            aboveEC1[i] < Const(0, width: 8),
            leftEC1[i] < Const(0, width: 8),
            aboveEC2[i] < Const(0, width: 8),
            leftEC2[i] < Const(0, width: 8),
          ],
          // mi grids must be zero for UNDECODED cells: a block's geometric
          // top-right neighbour can lie in a not-yet-decoded block (z-scan order).
          // SW reads it as non-inter (grids zero-init) and finds no candidate.
          for (var i = 0; i < miN * miN; i++) ...[
            miInter[i] < Const(0, width: 1),
            miRef0[i] < Const(0, width: 3),
            miMode[i] < Const(0, width: 5),
            miBs[i] < Const(0, width: 5),
            miMvR[i] < Const(0, width: 16),
            miMvC[i] < Const(0, width: 16),
          ],
          for (var i = 0; i < miN; i++) ...[
            abovePart[i] < Const(0, width: 5),
            leftPart[i] < Const(0, width: 5),
            aboveSkip[i] < Const(0),
            leftSkip[i] < Const(0),
          ],
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          symValid < Const(0),
          blockValid < Const(0),
          resValidReg < Const(0),
          Case(st, [
            CaseItem(Const(sIdle, width: stW), [
              If(
                input('start'),
                then: [
                  for (var i = 0; i < maxBytes; i++)
                    buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                  cursor < Const(0, width: cursor.width),
                  pli < Const(0, width: ecw),
                  symCnt < Const(0, width: 12),
                  for (var i = 0; i < miN * miN; i++) ...[
                    miInter[i] < Const(0, width: 1),
                    miRef0[i] < Const(0, width: 3),
                    miMode[i] < Const(0, width: 5),
                    miBs[i] < Const(0, width: 5),
                    miMvR[i] < Const(0, width: 16),
                    miMvC[i] < Const(0, width: 16),
                    miRef1[i] < Const(0, width: 3),
                    miMvR1[i] < Const(0, width: 16),
                    miMvC1[i] < Const(0, width: 16),
                    miSkipMode[i] < Const(0, width: 1),
                    miCompGrp[i] < Const(0, width: 1),
                    miII[i] < Const(0, width: 1),
                  ],
                  for (var i = 0; i < miN; i++) ...[
                    abovePart[i] < Const(0, width: 5),
                    leftPart[i] < Const(0, width: 5),
                    aboveSkip[i] < Const(0),
                    leftSkip[i] < Const(0),
                    aboveEC0[i] < Const(0, width: 8),
                    leftEC0[i] < Const(0, width: 8),
                    aboveTxfm[i] < Const(64, width: 7),
                    leftTxfm[i] < Const(64, width: 7),
                  ],
                  for (var i = 0; i < 8; i++) ...[
                    aboveEC1[i] < Const(0, width: 8),
                    leftEC1[i] < Const(0, width: 8),
                    aboveEC2[i] < Const(0, width: 8),
                    leftEC2[i] < Const(0, width: 8),
                  ],
                  // seed partition stack with the 64x64 SB root.
                  stR[0] < Const(0, width: cW),
                  stC[0] < Const(0, width: cW),
                  stB[0] < Const(12, width: 5),
                  sp < Const(1, width: spW),
                  st < Const(sPreload, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: stW), [
              If(
                pli.eq(Const(numCtx - 1, width: ecw)),
                then: [st < Const(sInit, width: stW)],
                orElse: [pli < (pli + Const(1, width: ecw)).getRange(0, ecw)],
              ),
            ]),
            CaseItem(Const(sInit, width: stW), [st < Const(sPop, width: stW)]),
            CaseItem(Const(sPop, width: stW), [
              If(
                sp.eq(Const(0, width: spW)),
                then: [st < Const(sDone, width: stW)],
                orElse: [
                  nr < stackTop(stR),
                  nc < stackTop(stC),
                  nbs < stackTop(stB),
                  sp < (sp - Const(1, width: spW)),
                  If(
                    stackTop(stB).lt(Const(3, width: 5)),
                    then: [
                      // < BLOCK_8X8: no partition symbol, single block leaf.
                      lr[0] < stackTop(stR),
                      lc[0] < stackTop(stC),
                      lbs[0] < stackTop(stB),
                      leafN < Const(1, width: 3),
                      emitIdx < Const(0, width: 3),
                      st < Const(sLeaf, width: stW),
                    ],
                    orElse: [st < Const(sPartDec, width: stW)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sPartDec, width: stW), [
              st < Const(sPartCap, width: stW),
            ]),
            CaseItem(Const(sPartCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              emitIdx < Const(0, width: 3),
              Case(sym.getRange(0, 4), [
                CaseItem(
                  Const(0, width: 4),
                  plan([
                    [nr, nc, subOf(0)],
                  ]),
                ),
                CaseItem(
                  Const(1, width: 4),
                  plan([
                    [nr, nc, subOf(1)],
                    [rPlus(half), nc, subOf(1)],
                  ]),
                ),
                CaseItem(
                  Const(2, width: 4),
                  plan([
                    [nr, nc, subOf(2)],
                    [nr, cPlus(half), subOf(2)],
                  ]),
                ),
                CaseItem(Const(3, width: 4), [
                  ...writeStack(sp, rPlus(half), cPlus(half), subOf(3)),
                  ...writeStack(
                    (sp + Const(1, width: spW)).getRange(0, spW),
                    rPlus(half),
                    nc,
                    subOf(3),
                  ),
                  ...writeStack(
                    (sp + Const(2, width: spW)).getRange(0, spW),
                    nr,
                    cPlus(half),
                    subOf(3),
                  ),
                  ...writeStack(
                    (sp + Const(3, width: spW)).getRange(0, spW),
                    nr,
                    nc,
                    subOf(3),
                  ),
                  sp < (sp + Const(4, width: spW)).getRange(0, spW),
                  st < Const(sPop, width: stW),
                ]),
                CaseItem(
                  Const(4, width: 4),
                  plan([
                    [nr, nc, subOf(3)],
                    [nr, cPlus(half), subOf(3)],
                    [rPlus(half), nc, subOf(4)],
                  ]),
                ),
                CaseItem(
                  Const(5, width: 4),
                  plan([
                    [nr, nc, subOf(5)],
                    [rPlus(half), nc, subOf(3)],
                    [rPlus(half), cPlus(half), subOf(3)],
                  ]),
                ),
                CaseItem(
                  Const(6, width: 4),
                  plan([
                    [nr, nc, subOf(3)],
                    [rPlus(half), nc, subOf(3)],
                    [nr, cPlus(half), subOf(6)],
                  ]),
                ),
                CaseItem(
                  Const(7, width: 4),
                  plan([
                    [nr, nc, subOf(7)],
                    [nr, cPlus(half), subOf(3)],
                    [rPlus(half), cPlus(half), subOf(3)],
                  ]),
                ),
                CaseItem(
                  Const(8, width: 4),
                  plan([
                    [nr, nc, subOf(8)],
                    [rPlus(quarter), nc, subOf(8)],
                    [rPlus((quarter + quarter).getRange(0, cW)), nc, subOf(8)],
                    [
                      rPlus((quarter + quarter + quarter).getRange(0, cW)),
                      nc,
                      subOf(8),
                    ],
                  ]),
                ),
                CaseItem(
                  Const(9, width: 4),
                  plan([
                    [nr, nc, subOf(9)],
                    [nr, cPlus(quarter), subOf(9)],
                    [nr, cPlus((quarter + quarter).getRange(0, cW)), subOf(9)],
                    [
                      nr,
                      cPlus((quarter + quarter + quarter).getRange(0, cW)),
                      subOf(9),
                    ],
                  ]),
                ),
              ]),
            ]),
            // HORZ4/VERT4 have a 4th leaf, handle it by re-planning after the
            // 3-leaf plan finishes. For this frame HORZ4 appears (bs 32x8 at r=8),
            // so emit the 4th leaf via a plan extension: use emitIdx==leafN check
            // in sLeaf with a stored "extra" leaf.
            CaseItem(Const(sLeaf, width: stW), [
              If(
                emitIdx.eq(leafN),
                then: [
                  // all planned leaves emitted, go pop next node.
                  st < Const(sPop, width: stW),
                ],
                orElse: [
                  // start decoding block emitIdx.
                  br < arrRd(lr, emitIdx, cW),
                  bc < arrRd(lc, emitIdx, cW),
                  bbs < arrRd(lbs, emitIdx, 5),
                  emitIdx < (emitIdx + Const(1, width: 3)),
                  // default this block's compound state to single-ref/no-skip-mode.
                  skipModeReg < Const(0),
                  ref1R < Const(0, width: 3),
                  compTypeReg < Const(0, width: 2),
                  compGrpReg < Const(0),
                  mvRow1Reg < Const(0, width: 16),
                  mvCol1Reg < Const(0, width: 16),
                  // default motion_mode SIMPLE (compound/intra blocks never read it).
                  motionModeReg < Const(0, width: 2),
                  // default interintra off (only single-ref blocks may set it).
                  iiReg < Const(0),
                  iiModeReg < Const(0, width: 2),
                  iiWedgeReg < Const(0),
                  iiWedgeIdxReg < Const(0, width: 4),
                  st < Const(sSkipModeDec, width: stW),
                ],
              ),
            ]),
            // skip_mode (compound REFERENCE_MODE_SELECT frames)
            CaseItem(Const(sSkipModeDec, width: stW), [
              // read skip_mode only when present and the block is comp-ref-allowed,
              // otherwise fall straight through to the skip flag.
              If(
                skipModePresent & compRefAllowed,
                then: [st < Const(sSkipModeCap, width: stW)],
                orElse: [st < Const(sSkipDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sSkipModeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  // skip_mode == 1: compound with the fixed skipModeFrame pair,
                  // NEAREST_NEARESTMV, AVERAGE, skip = 1. No further mode symbols,
                  // resolve the 2 MVs via the compound ref-mv candidate padding.
                  skipModeReg < Const(1),
                  skipReg < Const(1),
                  isIntraReg < Const(0),
                  ref0R < skipRef0,
                  ref1R < skipRef1,
                  modeR < Const(17, width: 5), // NEAREST_NEARESTMV
                  compTypeReg < Const(0, width: 2), // AVERAGE
                  st < Const(sCompExtraInit, width: stW),
                ],
                orElse: [
                  skipModeReg < Const(0),
                  st < Const(sSkipDec, width: stW),
                ],
              ),
            ]),
            // block decode
            CaseItem(Const(sSkipDec, width: stW), [
              st < Const(sSkipCap, width: stW),
            ]),
            CaseItem(Const(sSkipCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              skipReg < sym.getRange(0, 1),
              st < Const(sIsInterDec, width: stW),
            ]),
            CaseItem(Const(sIsInterDec, width: stW), [
              st < Const(sIsInterCap, width: stW),
            ]),
            CaseItem(Const(sIsInterCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              srIdx < Const(0, width: 3),
              If(
                sym.getRange(0, 1),
                then: [
                  // inter block: comp_mode -> single_ref/comp_ref -> mode/MV.
                  isIntraReg < Const(0),
                  st < Const(sCompModeDec, width: stW),
                ],
                orElse: [
                  // intra block inside the inter frame (read_intra_block_mode_info).
                  isIntraReg < Const(1),
                  st < Const(sIntraY, width: stW),
                ],
              ),
            ]),
            // comp_mode (reference_select): SINGLE vs COMPOUND
            CaseItem(Const(sCompModeDec, width: stW), [
              If(
                refModeSelect & compRefAllowed,
                then: [st < Const(sCompModeCap, width: stW)],
                orElse: [st < Const(sSrDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sCompModeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              // comp_mode == 0 -> single-ref (existing path). comp_mode == 1 ->
              // explicit compound: read the compound ref pair (comp_ref_type then
              // the fwd/bwd refs), then compound find_mv_refs + inter mode + type.
              If(
                sym.getRange(0, 1),
                then: [st < Const(sCompRefTypeDec, width: stW)],
                orElse: [st < Const(sSrDec, width: stW)],
              ),
            ]),
            // explicit-compound ref pair (read_ref_frames COMPOUND)
            CaseItem(Const(sCompRefTypeDec, width: stW), [
              st < Const(sCompRefTypeCap, width: stW),
            ]),
            CaseItem(Const(sCompRefTypeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  // BIDIR_COMP_REFERENCE: fwd ref (compRef tree) then bwd ref.
                  crPhase < Const(0, width: 3),
                  st < Const(sCompRefDec, width: stW),
                ],
                orElse: [
                  // UNIDIR_COMP_REFERENCE: uni_comp_ref tree.
                  crPhase < Const(0, width: 3),
                  // reuse crPhase as the uni tree phase, jump to the uni decode by
                  // setting a high bit (phase>=5 means uni). Encode uni phase 0 as 5.
                  crPhase < Const(5, width: 3),
                  st < Const(sCompRefDec, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sCompRefDec, width: stW), [
              st < Const(sCompRefCap, width: stW),
            ]),
            CaseItem(Const(sCompRefCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              Case(crPhase, [
                // BIDIR fwd ref
                CaseItem(Const(0, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      crPhase < Const(1, width: 3),
                      st < Const(sCompRefDec, width: stW),
                    ],
                    orElse: [
                      crPhase < Const(2, width: 3),
                      st < Const(sCompRefDec, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(1, width: 3), [
                  // LAST(1) vs LAST2(2). then bwd.
                  ref0R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(1, width: 3),
                        Const(2, width: 3),
                      ),
                  crPhase < Const(3, width: 3),
                  st < Const(sCompRefDec, width: stW),
                ]),
                CaseItem(Const(2, width: 3), [
                  // LAST3(3) vs GOLDEN(4). then bwd.
                  ref0R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(3, width: 3),
                        Const(4, width: 3),
                      ),
                  crPhase < Const(3, width: 3),
                  st < Const(sCompRefDec, width: stW),
                ]),
                // BIDIR bwd ref
                CaseItem(Const(3, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      crPhase < Const(4, width: 3),
                      st < Const(sCompRefDec, width: stW),
                    ],
                    orElse: [
                      ref1R < Const(7, width: 3),
                      st < Const(sCompExtraInit, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(4, width: 3), [
                  // BWDREF(5) vs ALTREF2(6).
                  ref1R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(5, width: 3),
                        Const(6, width: 3),
                      ),
                  st < Const(sCompExtraInit, width: stW),
                ]),
                // UNIDIR uni_comp_ref tree (phase 5..7)
                CaseItem(Const(5, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      // uni sub 1: LAST vs {LAST2 / LAST3 GOLDEN}.
                      crPhase < Const(6, width: 3),
                      st < Const(sCompRefDec, width: stW),
                    ],
                    orElse: [
                      // {LAST, ALTREF}.
                      ref0R < Const(1, width: 3), ref1R < Const(7, width: 3),
                      st < Const(sCompExtraInit, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(6, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      // {LAST, LAST2}.
                      ref0R < Const(1, width: 3), ref1R < Const(2, width: 3),
                      st < Const(sCompExtraInit, width: stW),
                    ],
                    orElse: [
                      crPhase < Const(7, width: 3),
                      st < Const(sCompRefDec, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(7, width: 3), [
                  // {LAST, GOLDEN} vs {LAST, LAST3}.
                  ref0R < Const(1, width: 3),
                  ref1R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(4, width: 3),
                        Const(3, width: 3),
                      ),
                  st < Const(sCompExtraInit, width: stW),
                ]),
              ]),
            ]),
            // compound ref-mv candidate padding (skip_mode block)
            CaseItem(Const(sCompExtraInit, width: stW), [
              // The compound nearest scans yield 0 candidates for the scoped frame
              // (no compound neighbours exist), so the count==0 padding branch runs
              // directly. mode_context = 0 (nearestMatch=refMatch=0), refMvCount = 2.
              fmModeCtx < Const(0, width: 8),
              fmCount < Const(2, width: 4),
              ce0IdF < Const(0), ce0DfF < Const(0),
              ce1IdF < Const(0), ce1DfF < Const(0),
              ce0IdR < Const(0, width: 16), ce0IdC < Const(0, width: 16),
              ce0DfR < Const(0, width: 16), ce0DfC < Const(0, width: 16),
              ce1IdR < Const(0, width: 16), ce1IdC < Const(0, width: 16),
              ce1DfR < Const(0, width: 16), ce1DfC < Const(0, width: 16),
              ce0Id2F < Const(0), ce0Df2F < Const(0),
              ce1Id2F < Const(0), ce1Df2F < Const(0),
              ce0Id2R < Const(0, width: 16), ce0Id2C < Const(0, width: 16),
              ce0Df2R < Const(0, width: 16), ce0Df2C < Const(0, width: 16),
              ce1Id2R < Const(0, width: 16), ce1Id2C < Const(0, width: 16),
              ce1Df2R < Const(0, width: 16), ce1Df2C < Const(0, width: 16),
              ceIdx < Const(0, width: oW),
              If(
                absO(maxRow).gte(Const(1, width: oW)),
                then: [
                  cePhase < Const(0),
                  st < Const(sCompExtraStep, width: stW),
                ],
                orElse: [
                  If(
                    absO(maxCol).gte(Const(1, width: oW)),
                    then: [
                      cePhase < Const(1),
                      st < Const(sCompExtraStep, width: stW),
                    ],
                    orElse: [st < Const(sCompResolve, width: stW)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sCompExtraStep, width: stW), [
              If(
                ceIdx.lt(ceMiSize.zeroExtend(oW)) & ceInside,
                then: [
                  // accumulate up to 2 exact-ref-match + 2 other-ref MVs per ref
                  // (refId[cmp][0..1], refDiff[cmp][0..1] in mvref_common.c).
                  If(
                    ce0[0],
                    then: [
                      If(
                        ~ce0IdF,
                        then: [
                          ce0IdF < Const(1),
                          ce0IdR < ce0[1],
                          ce0IdC < ce0[2],
                        ],
                        orElse: [
                          If(
                            ~ce0Id2F,
                            then: [
                              ce0Id2F < Const(1),
                              ce0Id2R < ce0[1],
                              ce0Id2C < ce0[2],
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    ce0[3],
                    then: [
                      If(
                        ~ce0DfF,
                        then: [
                          ce0DfF < Const(1),
                          ce0DfR < ce0[4],
                          ce0DfC < ce0[5],
                        ],
                        orElse: [
                          If(
                            ~ce0Df2F,
                            then: [
                              ce0Df2F < Const(1),
                              ce0Df2R < ce0[4],
                              ce0Df2C < ce0[5],
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    ce1[0],
                    then: [
                      If(
                        ~ce1IdF,
                        then: [
                          ce1IdF < Const(1),
                          ce1IdR < ce1[1],
                          ce1IdC < ce1[2],
                        ],
                        orElse: [
                          If(
                            ~ce1Id2F,
                            then: [
                              ce1Id2F < Const(1),
                              ce1Id2R < ce1[1],
                              ce1Id2C < ce1[2],
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  If(
                    ce1[3],
                    then: [
                      If(
                        ~ce1DfF,
                        then: [
                          ce1DfF < Const(1),
                          ce1DfR < ce1[4],
                          ce1DfC < ce1[5],
                        ],
                        orElse: [
                          If(
                            ~ce1Df2F,
                            then: [
                              ce1Df2F < Const(1),
                              ce1Df2R < ce1[4],
                              ce1Df2C < ce1[5],
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  ceIdx < (ceIdx + ceStep).getRange(0, oW),
                  st < Const(sCompExtraStep, width: stW),
                ],
                orElse: [
                  If(
                    ~cePhase & absO(maxCol).gte(Const(1, width: oW)),
                    then: [
                      cePhase < Const(1),
                      ceIdx < Const(0, width: oW),
                      st < Const(sCompExtraStep, width: stW),
                    ],
                    orElse: [
                      // skip_mode -> NEAREST_NEARESTMV resolve (stack[0]), explicit
                      // compound -> read the compound inter mode next.
                      If(
                        skipModeReg,
                        then: [st < Const(sCompResolve, width: stW)],
                        orElse: [st < Const(sInterCompModeDec, width: stW)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sCompResolve, width: stW), [
              mvRowReg < ceN0R,
              mvColReg < ceN0C,
              mvRow1Reg < ceN1R,
              mvCol1Reg < ceN1C,
              st < Const(sWriteMi, width: stW),
            ]),
            // explicit-compound inter mode
            CaseItem(Const(sInterCompModeDec, width: stW), [
              st < Const(sInterCompModeCap, width: stW),
            ]),
            CaseItem(Const(sInterCompModeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              // compound mode = NEAREST_NEARESTMV(17) + interCompoundMode symbol.
              modeR < (Const(17, width: 5) + sym.zeroExtend(5)).getRange(0, 5),
              drlIdxR < Const(0, width: 3),
              // DRL: NEW_NEWMV(24) reads from idx 0, NEAR_* modes from idx 1.
              If(
                sym.zeroExtend(5).eq(Const(7, width: 5)),
                then: [
                  // NEW_NEWMV.
                  drlPhase < Const(0, width: 3),
                  st < Const(sCompDrl, width: stW),
                ],
                orElse: [
                  // haveNearMv: NEAR_NEARMV(1), NEAR_NEWMV(4), NEW_NEARMV(5).
                  If(
                    sym.zeroExtend(5).eq(Const(1, width: 5)) |
                        sym.zeroExtend(5).eq(Const(4, width: 5)) |
                        sym.zeroExtend(5).eq(Const(5, width: 5)),
                    then: [
                      drlPhase < Const(1, width: 3),
                      st < Const(sCompDrl, width: stW),
                    ],
                    orElse: [st < Const(sCompResolveMv, width: stW)],
                  ),
                ],
              ),
            ]),
            // compound DRL (drlPhase = current idx)
            CaseItem(Const(sCompDrl, width: stW), [
              // NEW_NEWMV: idx 0..1, NEAR_*: idx 1..2. Condition refMvCount>idx+1.
              If(
                fmCount.gt(
                  (drlPhase.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
                ),
                then: [st < Const(sCompDrlDec, width: stW)],
                orElse: [st < Const(sCompResolveMv, width: stW)],
              ),
            ]),
            CaseItem(Const(sCompDrlDec, width: stW), [
              st < Const(sCompDrlCap, width: stW),
            ]),
            CaseItem(Const(sCompDrlCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                modeR.eq(Const(24, width: 5)),
                then: [
                  // NEW_NEWMV: refMvIdx = idx + drl, stop when drl==0 or idx==1.
                  drlIdxR <
                      (drlPhase.getRange(0, 3) + sym.getRange(0, 3)).getRange(
                        0,
                        3,
                      ),
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [st < Const(sCompResolveMv, width: stW)],
                    orElse: [
                      If(
                        drlPhase.eq(Const(1, width: 3)),
                        then: [st < Const(sCompResolveMv, width: stW)],
                        orElse: [
                          drlPhase < (drlPhase + Const(1, width: 3)),
                          st < Const(sCompDrl, width: stW),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [
                  // NEAR_*: refMvIdx = idx + drl - 1.
                  drlIdxR <
                      (drlPhase.getRange(0, 3) +
                              sym.getRange(0, 3) -
                              Const(1, width: 3))
                          .getRange(0, 3),
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [st < Const(sCompResolveMv, width: stW)],
                    orElse: [
                      If(
                        drlPhase.eq(Const(2, width: 3)),
                        then: [st < Const(sCompResolveMv, width: stW)],
                        orElse: [
                          drlPhase < (drlPhase + Const(1, width: 3)),
                          st < Const(sCompDrl, width: stW),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // compound MV resolve (NEAREST/NEAR/GLOBAL, NEW read_mv is a
            // future extension gated by a tractable NEW compound frame).
            CaseItem(Const(sCompResolveMv, width: stW), [
              // sub0 (ref0 component): NEAREST -> stack[0], NEAR -> stack[1+drl],
              // GLOBAL -> gmv(0,0). sub1 similarly from cols (2,3).
              mvRowReg < compMv0R,
              mvColReg < compMv0C,
              mvRow1Reg < compMv1R,
              mvCol1Reg < compMv1C,
              st < Const(sCompTypeGrpDec, width: stW),
            ]),
            // comp_type: comp_group_idx -> AVERAGE or wedge/diffwtd. The
            // enableJntComp (COMPOUND_DISTWTD via compound_idx) path is not in
            // scope (all target frames have enableJntComp == false).
            CaseItem(Const(sCompTypeGrpDec, width: stW), [
              // read comp_group_idx only when comp-ref-allowed & masked enabled,
              // else compGroupIdx = 0 (AVERAGE) with no symbol.
              If(
                compRefAllowed & maskedEn,
                then: [st < Const(sCompTypeGrpCap, width: stW)],
                orElse: [
                  compGrpReg < Const(0),
                  compTypeReg < Const(0, width: 2),
                  st < Const(sWriteMi, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sCompTypeGrpCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              compGrpReg < sym.getRange(0, 1),
              If(
                sym.getRange(0, 1),
                then: [
                  // comp_group_idx == 1: wedge/diffwtd.
                  st < Const(sCompTypeSymDec, width: stW),
                ],
                orElse: [
                  // comp_group_idx == 0: AVERAGE (jnt disabled in scope).
                  compTypeReg < Const(0, width: 2),
                  st < Const(sWriteMi, width: stW),
                ],
              ),
            ]),
            // comp_group_idx==1: wedge (if usable) vs diffwtd type symbol.
            CaseItem(Const(sCompTypeSymDec, width: stW), [
              If(
                wedgeUsed,
                then: [st < Const(sCompTypeSymCap, width: stW)],
                orElse: [
                  // wedge not usable -> DIFFWTD (type=1), read mask_type.
                  compTypeReg < Const(3, width: 2),
                  st < Const(sMaskTypeLoad, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sCompTypeSymCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  // WEDGE.
                  compTypeReg < Const(2, width: 2),
                  st < Const(sWedgeIdxDec, width: stW),
                ],
                orElse: [
                  // DIFFWTD.
                  compTypeReg < Const(3, width: 2),
                  st < Const(sMaskTypeLoad, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sMaskTypeLoad, width: stW), [
              st < Const(sMaskTypeDec, width: stW),
            ]),
            CaseItem(Const(sMaskTypeDec, width: stW), [
              st < Const(sMaskTypeCap, width: stW),
            ]),
            CaseItem(Const(sMaskTypeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              // mask_type is a literal bit, no state stored (recon uses it later).
              st < Const(sWriteMi, width: stW),
            ]),
            CaseItem(Const(sWedgeIdxDec, width: stW), [
              st < Const(sWedgeIdxCap, width: stW),
            ]),
            CaseItem(Const(sWedgeIdxCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              st < Const(sWedgeSignLoad, width: stW),
            ]),
            CaseItem(Const(sWedgeSignLoad, width: stW), [
              st < Const(sWedgeSignDec, width: stW),
            ]),
            CaseItem(Const(sWedgeSignDec, width: stW), [
              st < Const(sWedgeSignCap, width: stW),
            ]),
            CaseItem(Const(sWedgeSignCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              st < Const(sWriteMi, width: stW),
            ]),
            // intra block mode info
            CaseItem(Const(sIntraY, width: stW), [
              st < Const(sIntraYCap, width: stW),
            ]),
            CaseItem(Const(sIntraYCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              yModeReg < sym.zeroExtend(5),
              // set the grid/output regs for an intra block (MV = 0, ref = INTRA).
              modeR < sym.zeroExtend(5),
              ref0R < Const(0, width: 3),
              mvRowReg < Const(0, width: 16),
              mvColReg < Const(0, width: 16),
              // angle_delta_y only for directional y_mode when angle is enabled.
              If(
                useAngle &
                    sym.zeroExtend(5).gte(Const(1, width: 5)) &
                    sym.zeroExtend(5).lte(Const(8, width: 5)),
                then: [st < Const(sIntraAngleY, width: stW)],
                orElse: [st < Const(sIntraUv, width: stW)],
              ),
            ]),
            CaseItem(Const(sIntraAngleY, width: stW), [
              st < Const(sIntraAngleYCap, width: stW),
            ]),
            CaseItem(Const(sIntraAngleYCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              st < Const(sIntraUv, width: stW),
            ]),
            CaseItem(Const(sIntraUv, width: stW), [
              // uv_mode is present only when chroma_ref, else uvMode = DC (no read).
              If(
                chromaRef,
                then: [st < Const(sIntraUvCap, width: stW)],
                orElse: [
                  uvModeReg < Const(0, width: 5),
                  st < Const(sWriteMi, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sIntraUvCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              uvModeReg < sym.zeroExtend(5),
              // angle_delta_uv only for directional uv intra mode. (CFL / palette /
              // filter-intra do not occur in scope.)
              If(
                useAngle &
                    rom(_uv2y, sym, 5).gte(Const(1, width: 5)) &
                    rom(_uv2y, sym, 5).lte(Const(8, width: 5)),
                then: [st < Const(sIntraAngleUv, width: stW)],
                orElse: [st < Const(sWriteMi, width: stW)],
              ),
            ]),
            CaseItem(Const(sIntraAngleUv, width: stW), [
              st < Const(sIntraAngleUvCap, width: stW),
            ]),
            CaseItem(Const(sIntraAngleUvCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              st < Const(sWriteMi, width: stW),
            ]),
            CaseItem(Const(sSrDec, width: stW), [
              st < Const(sSrCap, width: stW),
            ]),
            CaseItem(Const(sSrCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              Case(srIdx, [
                CaseItem(Const(0, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      srIdx < Const(2, width: 3),
                      st < Const(sSrDec, width: stW),
                    ],
                    orElse: [
                      srIdx < Const(1, width: 3),
                      st < Const(sSrDec, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(2, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      srIdx < Const(3, width: 3),
                      st < Const(sSrDec, width: stW),
                    ],
                    orElse: [
                      srIdx < Const(4, width: 3),
                      st < Const(sSrDec, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(3, width: 3), [
                  ref0R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(1, width: 3),
                        Const(2, width: 3),
                      ),
                  st < Const(sFmv, width: stW),
                ]),
                CaseItem(Const(4, width: 3), [
                  ref0R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(3, width: 3),
                        Const(4, width: 3),
                      ),
                  st < Const(sFmv, width: stW),
                ]),
                CaseItem(Const(1, width: 3), [
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [
                      srIdx < Const(5, width: 3),
                      st < Const(sSrDec, width: stW),
                    ],
                    orElse: [
                      ref0R < Const(7, width: 3),
                      st < Const(sFmv, width: stW),
                    ],
                  ),
                ]),
                CaseItem(Const(5, width: 3), [
                  ref0R <
                      mux<Logic>(
                        sym.eq(Const(0, width: ec.symWidth)),
                        Const(5, width: 3),
                        Const(6, width: 3),
                      ),
                  st < Const(sFmv, width: stW),
                ]),
              ]),
            ]),
            // find_mv_refs
            CaseItem(Const(sFmv, width: stW), [
              fmCount < Const(0, width: 4),
              fmModeCtx < Const(0, width: 8),
              fmRowMatch < Const(0, width: 5),
              fmColMatch < Const(0, width: 5),
              fmNewmv < Const(0, width: 5),
              fmNearestCount < Const(0, width: 4),
              fmNearestMatch < Const(0, width: 2),
              fmProcRows < Const(0, width: oW),
              fmProcCols < Const(0, width: oW),
              clampIdx < Const(0, width: 4),
              outIdx < Const(2, width: 3),
              if (enableTmvp) ...[fmGlobalMv < Const(0), tAvail < Const(0)],
              for (var i = 0; i < 8; i++) ...[
                fmStackR[i] < Const(0, width: 16),
                fmStackC[i] < Const(0, width: 16),
                fmStackW[i] < Const(0, width: 16),
              ],
              // phase 1: nearest scanRow(-1) if |maxRow|>=1
              If(
                absO(maxRow).gte(Const(1, width: oW)),
                then: startScan(
                  0,
                  sConst(-1),
                  false,
                  sFmvN2,
                  updProc: true,
                  countNew: true,
                ),
                orElse: [st < Const(sFmvN2, width: stW)],
              ),
            ]),
            CaseItem(Const(sFmvN2, width: stW), [
              If(
                absO(maxCol).gte(Const(1, width: oW)),
                then: startScan(
                  1,
                  sConst(-1),
                  true,
                  sFmvN3,
                  updProc: true,
                  countNew: true,
                ),
                orElse: [st < Const(sFmvN3, width: stW)],
              ),
            ]),
            CaseItem(Const(sFmvN3, width: stW), [
              If(
                hasTopRightMv,
                then: startScan(
                  0,
                  sConst(0),
                  false,
                  sFmvNearW,
                  isBlk: true,
                  countNew: true,
                  blkR: (brS - sConst(1)).getRange(0, oW),
                  blkC: (bcS + sx(bw4)).getRange(0, oW),
                ),
                orElse: [st < Const(sFmvNearW, width: stW)],
              ),
            ]),
            CaseItem(Const(sFmvNearW, width: stW), [
              // snapshot nearestMatch, nearestCount, add 640 to nearest weights.
              fmNearestCount < fmCount,
              fmNearestMatch <
                  (fmRowMatch.gt(Const(0, width: 5)).zeroExtend(2) +
                          fmColMatch.gt(Const(0, width: 5)).zeroExtend(2))
                      .getRange(0, 2),
              for (var i = 0; i < 8; i++)
                If(
                  Const(i, width: 4).lt(fmCount),
                  then: [
                    fmStackW[i] <
                        (fmStackW[i] + Const(640, width: 16)).getRange(0, 16),
                  ],
                ),
              // TMVP temporal scan (add_temporal_candidates) runs between the
              // nearest scan and the top-left/outer scan (SW order). Init the
              // sample loop, skip straight to top-left when disabled.
              if (enableTmvp)
                If(
                  input('use_ref_frame_mvs'),
                  then: [
                    tPhase < Const(0),
                    tExtIdx < Const(0, width: 2),
                    tBlkRow < sConst(0),
                    tBlkCol < sConst(0),
                    st < Const(sTmvpDisp, width: stW),
                  ],
                  orElse: [st < Const(sFmvTL, width: stW)],
                )
              else
                st < Const(sFmvTL, width: stW),
            ]),
            CaseItem(Const(sFmvTL, width: stW), [
              // top-left scanBlk(r-1,c-1), rowMatch only (no newmv, no proc).
              If(
                insideOf(
                  (brS - sConst(1)).getRange(0, oW),
                  (bcS - sConst(1)).getRange(0, oW),
                ),
                then: startScan(
                  0,
                  sConst(0),
                  false,
                  sFmvOuter,
                  isBlk: true,
                  blkR: (brS - sConst(1)).getRange(0, oW),
                  blkC: (bcS - sConst(1)).getRange(0, oW),
                ),
                orElse: [
                  outIdx < Const(2, width: 3),
                  st < Const(sFmvOuter, width: stW),
                ],
              ),
              outIdx < Const(2, width: 3),
            ]),
            CaseItem(Const(sFmvOuter, width: stW), [
              // outer rows/cols idx 2..3. outIdx: 2->idx2 row, 3->idx2 col,
              // 4->idx3 row, 5->idx3 col, else done.
              Case(
                outIdx,
                [
                  CaseItem(
                    Const(2, width: 3),
                    outerScan(
                      0,
                      2,
                      rowAdj,
                      maxRow,
                      fmProcRows,
                      Const(3, width: 3),
                    ),
                  ),
                  CaseItem(
                    Const(3, width: 3),
                    outerScan(
                      1,
                      2,
                      colAdj,
                      maxCol,
                      fmProcCols,
                      Const(4, width: 3),
                    ),
                  ),
                  CaseItem(
                    Const(4, width: 3),
                    outerScan(
                      0,
                      3,
                      rowAdj,
                      maxRow,
                      fmProcRows,
                      Const(5, width: 3),
                    ),
                  ),
                  CaseItem(
                    Const(5, width: 3),
                    outerScan(
                      1,
                      3,
                      colAdj,
                      maxCol,
                      fmProcCols,
                      Const(6, width: 3),
                    ),
                  ),
                ],
                defaultItem: [st < Const(sFmvModeCtx, width: stW)],
              ),
            ]),
            CaseItem(Const(sFmvModeCtx, width: stW), [
              // refMatch + mode_context (av1 mode_context_analyzer switch). The
              // globalmv bit (offset 3) set by the temporal scan is OR'd in.
              ..._modeCtx(
                fmModeCtx,
                fmNearestMatch,
                fmRowMatch,
                fmColMatch,
                fmNewmv,
                tGlobalMvBit,
              ),
              st < Const(sFmvSort0, width: stW),
            ]),
            CaseItem(Const(sFmvSort0, width: stW), [
              sortStart < Const(0, width: 4),
              sortEnd < fmNearestCount,
              sortLen < fmNearestCount,
              sortIdx < Const(1, width: 4),
              sortNr < Const(0, width: 4),
              sortRet < Const(sFmvSort1, width: 8),
              If(
                fmNearestCount.gt(Const(1, width: 4)),
                then: [st < Const(sSortPass, width: stW)],
                orElse: [st < Const(sFmvSort1, width: stW)],
              ),
            ]),
            CaseItem(Const(sFmvSort1, width: stW), [
              sortStart < fmNearestCount,
              sortEnd < fmCount,
              sortLen < (fmCount - fmNearestCount).getRange(0, 4),
              sortIdx < Const(1, width: 4),
              sortNr < Const(0, width: 4),
              sortRet < Const(sSrExtra, width: 8),
              If(
                (fmCount - fmNearestCount)
                    .getRange(0, 4)
                    .gt(Const(1, width: 4)),
                then: [st < Const(sSortPass, width: stW)],
                orElse: [st < Const(sSrExtra, width: stW)],
              ),
            ]),
            CaseItem(Const(sSortPass, width: stW), [
              // one adjacent compare-swap of the bubble sort at index sortIdx.
              If(
                sortIdx.lt(sortLen),
                then: [
                  // pLo = sortStart+sortIdx-1, compare w[pLo] < w[pLo+1] -> swap.
                  for (var k = 0; k < 7; k++)
                    If(
                      (sortStart + sortIdx - Const(1, width: 4))
                              .getRange(0, 4)
                              .eq(Const(k, width: 4)) &
                          fmStackW[k].lt(fmStackW[k + 1]),
                      then: [
                        fmStackW[k] < fmStackW[k + 1],
                        fmStackW[k + 1] < fmStackW[k],
                        fmStackR[k] < fmStackR[k + 1],
                        fmStackR[k + 1] < fmStackR[k],
                        fmStackC[k] < fmStackC[k + 1],
                        fmStackC[k + 1] < fmStackC[k],
                        sortNr < sortIdx,
                      ],
                    ),
                  sortIdx < (sortIdx + Const(1, width: 4)),
                  st < Const(sSortPass, width: stW),
                ],
                orElse: [
                  If(
                    sortNr.gt(Const(0, width: 4)),
                    then: [
                      sortLen < sortNr,
                      sortIdx < Const(1, width: 4),
                      sortNr < Const(0, width: 4),
                      st < Const(sSortPass, width: stW),
                    ],
                    orElse: [_gotoState(st, stW, sortRet)],
                  ),
                ],
              ),
            ]),
            // single-ref extra candidates (process_single_ref_mv_candidate).
            // Runs after sort, before clamp. Row (-1) then col (-1) neighbours,
            // one per step (neighbour width/height), each ref (>refIntra) added
            // to the stack (sign-bias negated, deduped), while refMvCount < 2.
            CaseItem(Const(sSrExtra, width: stW), [
              cePhase < Const(0),
              ceIdx < Const(0, width: oW),
              If(
                fmCount.gte(Const(2, width: 4)),
                then: [st < Const(sClamp, width: stW)],
                orElse: [
                  If(
                    absO(maxRow).gte(Const(1, width: oW)),
                    then: [st < Const(sSrExtraR0, width: stW)],
                    orElse: [
                      If(
                        absO(maxCol).gte(Const(1, width: oW)),
                        then: [
                          cePhase < Const(1),
                          st < Const(sSrExtraR0, width: stW),
                        ],
                        orElse: [st < Const(sClamp, width: stW)],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sSrExtraR0, width: stW), [
              // loop guard: stop the phase on full stack / not-inside / idx past.
              If(
                fmCount.gte(Const(2, width: 4)) |
                    ~ceInside |
                    ~ceIdx.lt(ceMiSize.zeroExtend(oW)),
                then: [
                  If(
                    ~cePhase & absO(maxCol).gte(Const(1, width: oW)),
                    then: [
                      cePhase < Const(1),
                      ceIdx < Const(0, width: oW),
                      st < Const(sSrExtraR0, width: stW),
                    ],
                    orElse: [st < Const(sClamp, width: stW)],
                  ),
                ],
                orElse: [
                  // rf0 candidate.
                  acR < srR0,
                  acC < srC0,
                  acMatch < srQ0,
                  st < Const(sSrExtraAdd0, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sSrExtraAdd0, width: stW), [
              If(
                acMatch & ~foundFlag & fmCount.lt(Const(8, width: 4)),
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      fmCount.eq(Const(i, width: 4)),
                      then: [
                        fmStackR[i] < acR,
                        fmStackC[i] < acC,
                        fmStackW[i] < Const(2, width: 16),
                      ],
                    ),
                  fmCount < (fmCount + Const(1, width: 4)),
                ],
              ),
              st < Const(sSrExtraR1, width: stW),
            ]),
            CaseItem(Const(sSrExtraR1, width: stW), [
              // rf1 candidate (uses the just-updated fmCount/stack for dedup).
              acR < srR1,
              acC < srC1,
              acMatch < srQ1,
              st < Const(sSrExtraAdd1, width: stW),
            ]),
            CaseItem(Const(sSrExtraAdd1, width: stW), [
              If(
                acMatch & ~foundFlag & fmCount.lt(Const(8, width: 4)),
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      fmCount.eq(Const(i, width: 4)),
                      then: [
                        fmStackR[i] < acR,
                        fmStackC[i] < acC,
                        fmStackW[i] < Const(2, width: 16),
                      ],
                    ),
                  fmCount < (fmCount + Const(1, width: 4)),
                ],
              ),
              ceIdx < (ceIdx + ceStep).getRange(0, oW),
              st < Const(sSrExtraR0, width: stW),
            ]),
            CaseItem(Const(sClamp, width: stW), [
              If(
                clampIdx.lt(fmCount),
                then: [
                  for (var i = 0; i < 8; i++)
                    If(
                      clampIdx.eq(Const(i, width: 4)),
                      then: [
                        fmStackR[i] < clampS(fmStackR[i], minRow, maxRowV),
                        fmStackC[i] < clampS(fmStackC[i], minCol, maxColV),
                      ],
                    ),
                  clampIdx < (clampIdx + Const(1, width: 4)),
                  st < Const(sClamp, width: stW),
                ],
                orElse: [
                  clampIdx < Const(0, width: 4),
                  st < Const(sModeDec, width: stW),
                ],
              ),
            ]),
            // generic scan engine
            CaseItem(Const(sScanStep, width: stW), [
              If(
                ~scInside | ~scI.lt(scEnd),
                then: [
                  // scan finished (or blk not inside) -> return
                  _gotoState(st, stW, scRet),
                ],
                orElse: [
                  // latch candidate + advance
                  acR < scNbMvR,
                  acC < scNbMvC,
                  acNew < scNbMode.eq(Const(16, width: 5)),
                  acMatch < (scNbInter & scNbRef0.eq(ref0R)),
                  acCol < scMatchCol,
                  acW <
                      mux(
                        scIsBlk,
                        Const(4, width: 16),
                        (scLen.zeroExtend(16) * scWeight.zeroExtend(16))
                            .getRange(0, 16),
                      ),
                  If(
                    scIsBlk,
                    then: [
                      scI < scEnd, // one-shot
                    ],
                    orElse: [
                      scI < (scI + scLen.zeroExtend(oW)).getRange(0, oW),
                      If(
                        scUpdProc & scWeightEligible,
                        then: [
                          If(
                            scDir,
                            then: [fmProcCols < scProc],
                            orElse: [fmProcRows < scProc],
                          ),
                        ],
                      ),
                    ],
                  ),
                  st < Const(sScanAdd, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sScanAdd, width: stW), [
              If(
                acMatch,
                then: [
                  If(
                    foundFlag,
                    then: [
                      for (var i = 0; i < 8; i++)
                        If(
                          foundIdx.eq(Const(i, width: 4)),
                          then: [
                            fmStackW[i] < (fmStackW[i] + acW).getRange(0, 16),
                          ],
                        ),
                    ],
                    orElse: [
                      If(
                        fmCount.lt(Const(8, width: 4)),
                        then: [
                          for (var i = 0; i < 8; i++)
                            If(
                              fmCount.eq(Const(i, width: 4)),
                              then: [
                                fmStackR[i] < acR,
                                fmStackC[i] < acC,
                                fmStackW[i] < acW,
                              ],
                            ),
                          fmCount < (fmCount + Const(1, width: 4)),
                        ],
                      ),
                    ],
                  ),
                  If(
                    acCol,
                    then: [fmColMatch < (fmColMatch + Const(1, width: 5))],
                    orElse: [fmRowMatch < (fmRowMatch + Const(1, width: 5))],
                  ),
                  If(
                    acNew & scCountNew,
                    then: [fmNewmv < (fmNewmv + Const(1, width: 5))],
                  ),
                ],
              ),
              st < Const(sScanStep, width: stW),
            ]),
            // single-ref extra + clamp handled above, modes below
            CaseItem(Const(sModeDec, width: stW), [
              st < Const(sModeNewCap, width: stW),
            ]),
            CaseItem(Const(sModeNewCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  modeR < Const(16, width: 5),
                  drlIdxR < Const(0, width: 3),
                  drlPhase < Const(0, width: 3),
                  st < Const(sDrl, width: stW),
                ],
                orElse: [st < Const(sZeroDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sZeroDec, width: stW), [
              st < Const(sZeroCap, width: stW),
            ]),
            CaseItem(Const(sZeroCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  modeR < Const(15, width: 5),
                  st < Const(sPred, width: stW),
                ],
                orElse: [st < Const(sRefDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sRefDec, width: stW), [
              st < Const(sRefCap, width: stW),
            ]),
            CaseItem(Const(sRefCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              modeR <
                  mux<Logic>(
                    sym.eq(Const(0, width: ec.symWidth)),
                    Const(13, width: 5),
                    Const(14, width: 5),
                  ),
              drlIdxR < Const(0, width: 3),
              // NEARMV takes DRL (haveNearMv), NEARESTMV does not.
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [st < Const(sPred, width: stW)],
                orElse: [
                  drlPhase < Const(1, width: 3),
                  st < Const(sDrl, width: stW),
                ],
              ),
            ]),
            // DRL
            CaseItem(Const(sDrl, width: stW), [
              // NEW: idx in 0..1, NEAR: idx in 1..2. drlPhase holds current idx.
              // condition: refMvCount > idx+1
              If(
                fmCount.gt(
                  (drlPhase.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
                ),
                then: [st < Const(sDrlDec, width: stW)],
                orElse: [st < Const(sPred, width: stW)],
              ),
            ]),
            CaseItem(Const(sDrlDec, width: stW), [
              st < Const(sDrlCap, width: stW),
            ]),
            CaseItem(Const(sDrlCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                modeR.eq(Const(16, width: 5)),
                then: [
                  // NEW: refMvIdx = idx + drl, if drl==0 done.
                  drlIdxR <
                      (drlPhase.getRange(0, 3) + sym.getRange(0, 3)).getRange(
                        0,
                        3,
                      ),
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [st < Const(sPred, width: stW)],
                    orElse: [
                      If(
                        drlPhase.eq(Const(1, width: 3)),
                        then: [st < Const(sPred, width: stW)],
                        orElse: [
                          drlPhase < (drlPhase + Const(1, width: 3)),
                          st < Const(sDrl, width: stW),
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [
                  // NEAR: refMvIdx = idx + drl - 1.
                  drlIdxR <
                      (drlPhase.getRange(0, 3) +
                              sym.getRange(0, 3) -
                              Const(1, width: 3))
                          .getRange(0, 3),
                  If(
                    sym.eq(Const(0, width: ec.symWidth)),
                    then: [st < Const(sPred, width: stW)],
                    orElse: [
                      If(
                        drlPhase.eq(Const(2, width: 3)),
                        then: [st < Const(sPred, width: stW)],
                        orElse: [
                          drlPhase < (drlPhase + Const(1, width: 3)),
                          st < Const(sDrl, width: stW),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ]),
            // predictor / read_mv
            CaseItem(Const(sPred, width: stW), [
              // Compute predictor per mode, for NEW go read_mv, else finalize mv.
              ..._predictor(
                modeR,
                drlIdxR,
                fmCount,
                fmStackR,
                fmStackC,
                allowHp,
                forceInt,
                predR,
                predC,
                mvRowReg,
                mvColReg,
                gmv0R,
                gmv0C,
                ec.symWidth,
              ),
              If(
                modeR.eq(Const(16, width: 5)),
                then: [
                  compReg < Const(0),
                  st < Const(sJointDec, width: stW),
                ],
                orElse: [st < Const(sIIChk, width: stW)],
              ),
            ]),
            CaseItem(Const(sJointDec, width: stW), [
              st < Const(sJointCap, width: stW),
            ]),
            CaseItem(Const(sJointCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              jointReg < sym.getRange(0, 2),
              needRow <
                  (sym.getRange(0, 2).eq(Const(2, width: 2)) |
                      sym.getRange(0, 2).eq(Const(3, width: 2))),
              needCol <
                  (sym.getRange(0, 2).eq(Const(1, width: 2)) |
                      sym.getRange(0, 2).eq(Const(3, width: 2))),
              mvRowReg < predR,
              mvColReg < predC,
              If(
                sym.getRange(0, 2).eq(Const(2, width: 2)) |
                    sym.getRange(0, 2).eq(Const(3, width: 2)),
                then: [
                  compReg < Const(0),
                  st < Const(sSignDec, width: stW),
                ],
                orElse: [
                  If(
                    sym.getRange(0, 2).eq(Const(1, width: 2)),
                    then: [
                      compReg < Const(1),
                      st < Const(sSignDec, width: stW),
                    ],
                    orElse: [st < Const(sIIChk, width: stW)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sSignDec, width: stW), [
              st < Const(sSignCap, width: stW),
            ]),
            CaseItem(Const(sSignCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              signReg < sym.getRange(0, 1),
              st < Const(sClassDec, width: stW),
            ]),
            CaseItem(Const(sClassDec, width: stW), [
              st < Const(sClassCap, width: stW),
            ]),
            CaseItem(Const(sClassCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              mvClassReg < sym.getRange(0, 4),
              dAcc < Const(0, width: 11),
              bitIx < Const(0, width: 4),
              If(
                sym.getRange(0, 4).eq(Const(0, width: 4)),
                then: [st < Const(sClass0Dec, width: stW)],
                orElse: [st < Const(sBitsDec, width: stW)],
              ),
            ]),
            CaseItem(Const(sClass0Dec, width: stW), [
              st < Const(sClass0Cap, width: stW),
            ]),
            CaseItem(Const(sClass0Cap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              dAcc < sym.getRange(0, 1).zeroExtend(11),
              If(
                useSubpel,
                then: [st < Const(sFpDec, width: stW)],
                orElse: [
                  frReg < Const(3, width: 2),
                  hpReg < Const(1),
                  st < Const(sCompAsm, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sBitsDec, width: stW), [
              st < Const(sBitsCap, width: stW),
            ]),
            CaseItem(Const(sBitsCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              dAcc <
                  (dAcc |
                          (sym.getRange(0, 1).zeroExtend(11) <<
                              bitIx.getRange(0, 4)))
                      .getRange(0, 11),
              If(
                (bitIx + Const(1, width: 4)).getRange(0, 4).lt(mvClassReg),
                then: [
                  bitIx < (bitIx + Const(1, width: 4)),
                  st < Const(sBitsDec, width: stW),
                ],
                orElse: [
                  If(
                    useSubpel,
                    then: [st < Const(sFpDec, width: stW)],
                    orElse: [
                      frReg < Const(3, width: 2),
                      hpReg < Const(1),
                      st < Const(sCompAsm, width: stW),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sFpDec, width: stW), [
              st < Const(sFpCap, width: stW),
            ]),
            CaseItem(Const(sFpCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              frReg < sym.getRange(0, 2),
              If(
                useHp,
                then: [st < Const(sHpDec, width: stW)],
                orElse: [
                  hpReg < Const(1),
                  st < Const(sCompAsm, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sHpDec, width: stW), [
              st < Const(sHpCap, width: stW),
            ]),
            CaseItem(Const(sHpCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              hpReg < sym.getRange(0, 1),
              st < Const(sCompAsm, width: stW),
            ]),
            CaseItem(Const(sCompAsm, width: stW), [
              If(
                compReg.eq(Const(0)),
                then: [
                  mvRowReg < (predR + compVal).getRange(0, 16),
                  If(
                    needCol,
                    then: [
                      compReg < Const(1),
                      st < Const(sSignDec, width: stW),
                    ],
                    orElse: [st < Const(sIIChk, width: stW)],
                  ),
                ],
                orElse: [
                  mvColReg < (predC + compVal).getRange(0, 16),
                  st < Const(sIIChk, width: stW),
                ],
              ),
            ]),
            // interintra (single-ref) entropy decode
            CaseItem(Const(sIIChk, width: stW), [
              iiReg < Const(0),
              iiWedgeReg < Const(0),
              If(
                input('enable_interintra') & iiAllowed,
                then: [st < Const(sIIDec, width: stW)],
                orElse: [st < Const(sMmChk, width: stW)],
              ),
            ]),
            CaseItem(Const(sIIDec, width: stW), [
              st < Const(sIICap, width: stW),
            ]),
            CaseItem(Const(sIICap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [
                  // interintra == 0: normal single-ref, go to motion_mode.
                  st < Const(sMmChk, width: stW),
                ],
                orElse: [
                  iiReg < Const(1),
                  st < Const(sIIModeDec, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sIIModeDec, width: stW), [
              st < Const(sIIModeCap, width: stW),
            ]),
            CaseItem(Const(sIIModeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              iiModeReg < sym.getRange(0, 2),
              If(
                wedgeUsed,
                then: [st < Const(sIIWedgeDec, width: stW)],
                orElse: [st < Const(sMmChk, width: stW)],
              ),
            ]),
            CaseItem(Const(sIIWedgeDec, width: stW), [
              st < Const(sIIWedgeCap, width: stW),
            ]),
            CaseItem(Const(sIIWedgeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.eq(Const(0, width: ec.symWidth)),
                then: [st < Const(sMmChk, width: stW)],
                orElse: [
                  iiWedgeReg < Const(1),
                  st < Const(sIIWedgeIdxDec, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(sIIWedgeIdxDec, width: stW), [
              st < Const(sIIWedgeIdxCap, width: stW),
            ]),
            CaseItem(Const(sIIWedgeIdxCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              iiWedgeIdxReg < sym.getRange(0, 4),
              st < Const(sMmChk, width: stW),
            ]),
            // motion_mode (OBMC) decode
            CaseItem(Const(sMmChk, width: stW), [
              motionModeReg < Const(0, width: 2), // default SIMPLE
              mmHasOv < Const(0),
              // interintra forces SIMPLE motion_mode (no read): SW
              // _motionModeAllowed returns SIMPLE when _curInterIntra is set.
              If(
                mmEligible & ~iiReg,
                then: [
                  // scan the above row first (if any), then the left col (if any).
                  If(
                    br.gt(Const(0, width: cW)),
                    then: [
                      mmScan < bc,
                      st < Const(sMmAbove, width: stW),
                    ],
                    orElse: [
                      If(
                        bc.gt(Const(0, width: cW)),
                        then: [
                          mmScan < br,
                          st < Const(sMmLeft, width: stW),
                        ],
                        orElse: [
                          st <
                              Const(
                                sWriteMi,
                                width: stW,
                              ), // no overlappable nb -> SIMPLE
                        ],
                      ),
                    ],
                  ),
                ],
                orElse: [st < Const(sWriteMi, width: stW)],
              ),
            ]),
            CaseItem(Const(sMmAbove, width: stW), [
              If(
                mmAbInRange,
                then: [
                  If(mmAbInter, then: [mmHasOv < Const(1)]),
                  mmScan < mmAbNext,
                  st < Const(sMmAbove, width: stW),
                ],
                orElse: [
                  If(
                    bc.gt(Const(0, width: cW)),
                    then: [
                      mmScan < br,
                      st < Const(sMmLeft, width: stW),
                    ],
                    orElse: [st < Const(sMmResolve, width: stW)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sMmLeft, width: stW), [
              If(
                mmLtInRange,
                then: [
                  If(mmLtInter, then: [mmHasOv < Const(1)]),
                  mmScan < mmLtNext,
                  st < Const(sMmLeft, width: stW),
                ],
                orElse: [st < Const(sMmResolve, width: stW)],
              ),
            ]),
            CaseItem(Const(sMmResolve, width: stW), [
              // _motionModeAllowed: overlappable==0 -> SIMPLE (no read). Else, when
              // warp-eligible (allow_warped_motion && !force_integer_mv &&
              // num_warp_samples>=1, global/superres out of scope), read the
              // 3-value SIMPLE/OBMC/WARP motionModeCdf, otherwise the 2-value obmc.
              If(
                mmHasOv & ~globalMmSuppress,
                then: [
                  If(
                    input('allow_warped_motion') &
                        ~input('force_integer_mv') &
                        hasWarpSample,
                    then: [st < Const(sMmDec3, width: stW)],
                    orElse: [st < Const(sMmDec, width: stW)],
                  ),
                ],
                orElse: [
                  st < Const(sWriteMi, width: stW), // SIMPLE
                ],
              ),
            ]),
            CaseItem(Const(sMmDec, width: stW), [
              st < Const(sMmCap, width: stW),
            ]),
            CaseItem(Const(sMmCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              motionModeReg <
                  mux<Logic>(
                    sym.getRange(0, 1).eq(Const(0, width: 1)),
                    Const(0, width: 2),
                    Const(1, width: 2),
                  ),
              st < Const(sWriteMi, width: stW),
            ]),
            // 3-value motionModeCdf: sym 0=SIMPLE, 1=OBMC, 2=WARP.
            CaseItem(Const(sMmDec3, width: stW), [
              st < Const(sMmCap3, width: stW),
            ]),
            CaseItem(Const(sMmCap3, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              motionModeReg < sym.getRange(0, 2),
              st < Const(sWriteMi, width: stW),
            ]),
            // write mi + neighbour ctx
            CaseItem(Const(sWriteMi, width: stW), [
              // Intra blocks do not emit a block record (SW interBlockTrace is
              // inter-only) and mark the grid as intra so neighbours' is_inter /
              // single_ref / find_mv_refs correctly ignore them.
              blockValid < ~isIntraReg,
              // write mi grid for the block extent.
              for (var i = 0; i < miN; i++)
                for (var j = 0; j < miN; j++)
                  If(
                    _inBlock(
                      Const(i, width: 5),
                      Const(j, width: 5),
                      br,
                      bc,
                      bw4,
                      bh4,
                    ),
                    then: [
                      miInter[i * miN + j] < ~isIntraReg,
                      miRef0[i * miN + j] < ref0R,
                      miMode[i * miN + j] < modeR,
                      miBs[i * miN + j] < bbs,
                      miMvR[i * miN + j] < mvRowReg,
                      miMvC[i * miN + j] < mvColReg,
                      // compound 2nd ref (0 = single-ref) + skip_mode flag.
                      miRef1[i * miN + j] < ref1R,
                      miMvR1[i * miN + j] < mvRow1Reg,
                      miMvC1[i * miN + j] < mvCol1Reg,
                      miSkipMode[i * miN + j] < skipModeReg,
                      miCompGrp[i * miN + j] < compGrpReg,
                      // interintra marker (SW ref_frame[1] == INTRA_FRAME).
                      miII[i * miN + j] < iiReg,
                    ],
                  ),
              // above/left ctx (aboveSkip/leftSkip carry the actual skip flag).
              // aboveTxfm/leftTxfm carry the neighbour tx dims (px). For var-tx
              // (SELECT & !skip) the per-leaf setTxfmCtx does it during rVtEmit,
              // otherwise (skip or LARGEST) set them here to the block/tx dims.
              for (var i = 0; i < miN; i++) ...[
                If(
                  _inSpan(Const(i, width: 5), bc, bw4),
                  then: [
                    abovePart[i] < rom(_partCtxAbove, bbs, 5),
                    aboveSkip[i] < skipReg,
                  ],
                ),
                If(
                  _inSpan(Const(i, width: 5), br, bh4),
                  then: [
                    leftPart[i] < rom(_partCtxLeft, bbs, 5),
                    leftSkip[i] < skipReg,
                  ],
                ),
              ],
              If(
                ~(txModeSel & ~skipReg),
                then: [
                  for (var i = 0; i < miN; i++) ...[
                    If(
                      _inSpan(Const(i, width: 5), bc, bw4),
                      then: [
                        aboveTxfm[i] <
                            mux(
                              skipReg,
                              (bw4.zeroExtend(7) << 2).getRange(0, 7),
                              (rom(
                                        _txWideUnit,
                                        rom(_maxRectTx, bbs, 5),
                                        5,
                                      ).zeroExtend(7) <<
                                      2)
                                  .getRange(0, 7),
                            ),
                      ],
                    ),
                    If(
                      _inSpan(Const(i, width: 5), br, bh4),
                      then: [
                        leftTxfm[i] <
                            mux(
                              skipReg,
                              (bh4.zeroExtend(7) << 2).getRange(0, 7),
                              (rom(
                                        _txHighUnit,
                                        rom(_maxRectTx, bbs, 5),
                                        5,
                                      ).zeroExtend(7) <<
                                      2)
                                  .getRange(0, 7),
                            ),
                      ],
                    ),
                  ],
                ],
              ),
              // Skip block resets the entropy context over its extent (luma,
              // chroma EC is 0 in scope). Non-skip: decode the residual.
              If(
                skipReg,
                then: [
                  for (var i = 0; i < 16; i++) ...[
                    If(
                      _inSpan(Const(i, width: 5), bc, bw4),
                      then: [aboveEC0[i] < Const(0, width: 8)],
                    ),
                    If(
                      _inSpan(Const(i, width: 5), br, bh4),
                      then: [leftEC0[i] < Const(0, width: 8)],
                    ),
                  ],
                  st < Const(sLeaf, width: stW),
                ],
                orElse: [st < Const(rResInit, width: stW)],
              ),
            ]),
            // residual sequencing (var-tx tree + generic leaf coeff)
            CaseItem(Const(rResInit, width: stW), [
              resPlane < Const(0, width: 2),
              vtCur < Const(0, width: 3),
              blkLumaTxType < Const(0, width: 5),
              If(
                txModeSel,
                then: [
                  // var-tx: one maxTx tree node at the block origin (BLOCK_8X8 scope).
                  vtNodeR < br,
                  vtNodeC < bc,
                  vtNodeTx < rom(_maxRectTx, bbs, 5),
                  st < Const(rTxfmPartDec, width: stW),
                ],
                orElse: [
                  // LARGEST: a single luma leaf covering the block.
                  vtSz[0] < rom(_maxRectTx, bbs, 5),
                  vtIdy[0] < Const(0, width: 5),
                  vtIdx[0] < Const(0, width: 5),
                  vtN < Const(1, width: 3),
                  st < Const(rLeafNext, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(rTxfmPartDec, width: stW), [
              st < Const(rTxfmPartCap, width: stW),
            ]),
            CaseItem(Const(rTxfmPartCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              vtSplitR < sym.getRange(0, 1),
              st < Const(rVtEmit, width: stW),
            ]),
            CaseItem(Const(rVtEmit, width: stW), [
              // BLOCK_8X8 maxTx=TX_8X8: split -> 4 TX_4X4 leaves, else 1 TX_8X8.
              If(
                vtSplitR,
                then: [
                  vtSz[0] < Const(0, width: 5),
                  vtIdy[0] < Const(0, width: 5),
                  vtIdx[0] < Const(0, width: 5),
                  vtSz[1] < Const(0, width: 5),
                  vtIdy[1] < Const(0, width: 5),
                  vtIdx[1] < Const(1, width: 5),
                  vtSz[2] < Const(0, width: 5),
                  vtIdy[2] < Const(1, width: 5),
                  vtIdx[2] < Const(0, width: 5),
                  vtSz[3] < Const(0, width: 5),
                  vtIdy[3] < Const(1, width: 5),
                  vtIdx[3] < Const(1, width: 5),
                  vtN < Const(4, width: 3),
                  // setTxfmCtx per TX_4X4 leaf (wpx=hpx=4) over the block extent.
                  for (var i = 0; i < 16; i++) ...[
                    If(
                      _inSpan(Const(i, width: 5), bc, bw4),
                      then: [aboveTxfm[i] < Const(4, width: 7)],
                    ),
                    If(
                      _inSpan(Const(i, width: 5), br, bh4),
                      then: [leftTxfm[i] < Const(4, width: 7)],
                    ),
                  ],
                ],
                orElse: [
                  vtSz[0] < Const(1, width: 5),
                  vtIdy[0] < Const(0, width: 5),
                  vtIdx[0] < Const(0, width: 5),
                  vtN < Const(1, width: 3),
                  for (var i = 0; i < 16; i++) ...[
                    If(
                      _inSpan(Const(i, width: 5), bc, bw4),
                      then: [aboveTxfm[i] < Const(8, width: 7)],
                    ),
                    If(
                      _inSpan(Const(i, width: 5), br, bh4),
                      then: [leftTxfm[i] < Const(8, width: 7)],
                    ),
                  ],
                ],
              ),
              st < Const(rLeafNext, width: stW),
            ]),
            CaseItem(Const(rLeafNext, width: stW), [
              If(
                vtCur.gte(vtN),
                then: [
                  // All luma leaves done. Chroma (4:2:0) is coded only when this block
                  // is the chroma reference (av1 is_chroma_reference). A non-reference
                  // sub-block, e.g. an even-column BLOCK_4X16 VERT_4 leaf whose
                  // chroma is deferred to the reference block covering the 2-column
                  // group, codes NO chroma txb_skip, decoding it here would consume
                  // extra od_ec symbols and desync the stream. Skip straight to block
                  // completion (sLeaf) when chromaRef is false.
                  If(
                    chromaRef,
                    then: [
                      // Set up plane 1: chroma tx size, chroma-plane origin (luma-mi >>
                      // 1), forced tx_type = the block's co-located luma tx_type,
                      // cleared level buffers + EC accumulators.
                      resPlane < Const(1, width: 2),
                      curTxSize < rom(_uvTx420, bbs, 5),
                      curPlane < Const(1, width: 2),
                      curAOff < (bc >> Const(1, width: 5)).getRange(0, 5),
                      curLOff < (br >> Const(1, width: 5)).getRange(0, 5),
                      txTypeReg < blkLumaTxType,
                      txClassReg < rom(_txClass16, blkLumaTxType, 2),
                      culLevelReg < Const(0, width: 7),
                      dcValNeg < Const(0), dcValPos < Const(0),
                      // cc level buffers cleared via lvlClear (rLeafNext, luma done).
                      st < Const(rCSkipDec, width: stW),
                    ],
                    orElse: [st < Const(sLeaf, width: stW)],
                  ),
                ],
                orElse: [st < Const(rLeafSetup, width: stW)],
              ),
            ]),
            CaseItem(Const(rLeafSetup, width: stW), [
              curTxSize < arrRd(vtSz, vtCur, 5),
              curPlane < Const(0, width: 2),
              curAOff <
                  (bc.zeroExtend(5) + arrRd(vtIdx, vtCur, 5)).getRange(0, 5),
              curLOff <
                  (br.zeroExtend(5) + arrRd(vtIdy, vtCur, 5)).getRange(0, 5),
              culLevelReg < Const(0, width: 7),
              dcValNeg < Const(0), dcValPos < Const(0),
              // cc level buffers cleared via lvlClear (rLeafSetup, luma leaf).
              st < Const(rYSkipDec, width: stW),
            ]),
            CaseItem(Const(rEcWrite, width: stW), [
              ...setEntropyCtx(0, curAOff, curLOff),
              vtCur < (vtCur + Const(1, width: 3)),
              st < Const(rLeafNext, width: stW),
            ]),
            // residual coeff decode
            // Y txb_skip (TX_16X16, txsCtx 2, skipCtx 0).
            CaseItem(Const(rYSkipDec, width: stW), [
              st < Const(rYSkipCap, width: stW),
            ]),
            CaseItem(Const(rYSkipCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  // all-zero luma -> write EC (culLevel 0) + advance to next leaf.
                  culLevelReg < Const(0, width: 7),
                  dcValNeg < Const(0), dcValPos < Const(0),
                  st < Const(rEcWrite, width: stW),
                ],
                orElse: [st < Const(rTxTypeDec, width: stW)],
              ),
            ]),
            // inter tx_type: ext-tx set 5 (16-sym, TX_4X4/TX_8X8) or set 4 (12-sym,
            // TX_16X16). txClass derives from the resolved TX_TYPE via _txClass16.
            CaseItem(Const(rTxTypeDec, width: stW), [
              st < Const(rTxTypeCap, width: stW),
            ]),
            CaseItem(Const(rTxTypeCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)), symValid < Const(1),
              txTypeReg < rTxTypeSym,
              txClassReg < rTxClassSym,
              // remember this luma leaf's tx_type to force the block's chroma tx.
              blkLumaTxType < rTxTypeSym,
              st < Const(rEobPtDec, width: stW),
            ]),
            // eob_pt (TX_16X16 luma, 9-sym, 2D vs 1D ctx by tx class).
            CaseItem(Const(rEobPtDec, width: stW), [
              st < Const(rEobPtCap, width: stW),
            ]),
            CaseItem(Const(rEobPtCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              eobPtReg <
                  (sym.getRange(0, 4) + Const(1, width: 4)).getRange(0, 4),
              st < Const(rExtra, width: stW),
            ]),
            // eob_extra dispatch: offBits==0 -> eob settled, else decode bits.
            CaseItem(Const(rExtra, width: stW), [
              offBitsR < offBits,
              eobExtraR < Const(0, width: 11),
              If(
                offBits.eq(Const(0, width: 4)),
                then: [
                  eobReg < groupStart,
                  cIdx < (groupStart - Const(1, width: 11)).getRange(0, 8),
                  brIdxR < Const(0, width: 3),
                  st < Const(rBaseDec, width: stW),
                ],
                orElse: [st < Const(rExtraDec, width: stW)],
              ),
            ]),
            // adaptive eob_extra top bit.
            CaseItem(Const(rExtraDec, width: stW), [
              st < Const(rExtraCap, width: stW),
            ]),
            CaseItem(Const(rExtraCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  eobExtraR <
                      (Const(1, width: 11) <<
                              (offBitsR - Const(1, width: 4)).getRange(0, 4))
                          .getRange(0, 11),
                ],
              ),
              bypIdxR < Const(1, width: 4),
              st < Const(rByp, width: stW),
            ]),
            // eob_extra bypass bits dispatch.
            CaseItem(Const(rByp, width: stW), [
              If(
                bypIdxR.gte(offBitsR),
                then: [
                  // eob settled: eob = groupStart(+extra if >2).
                  eobReg <
                      mux(
                        groupStart.gt(Const(2, width: 11)),
                        (groupStart + eobExtraR).getRange(0, 11),
                        groupStart,
                      ),
                  cIdx <
                      (mux(
                                groupStart.gt(Const(2, width: 11)),
                                (groupStart + eobExtraR).getRange(0, 11),
                                groupStart,
                              ) -
                              Const(1, width: 11))
                          .getRange(0, 8),
                  brIdxR < Const(0, width: 3),
                  st < Const(rBaseDec, width: stW),
                ],
                orElse: [st < Const(rBypLoad, width: stW)],
              ),
            ]),
            CaseItem(Const(rBypLoad, width: stW), [
              st < Const(rBypDec, width: stW),
            ]),
            CaseItem(Const(rBypDec, width: stW), [
              st < Const(rBypCap, width: stW),
            ]),
            CaseItem(Const(rBypCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  eobExtraR <
                      (eobExtraR |
                              (Const(1, width: 11) <<
                                      (offBitsR - Const(1, width: 4) - bypIdxR)
                                          .getRange(0, 4))
                                  .getRange(0, 11))
                          .getRange(0, 11),
                ],
              ),
              bypIdxR < (bypIdxR + Const(1, width: 4)),
              st < Const(rByp, width: stW),
            ]),
            // coeff_base reverse scan (cIdx = eob-1 .. 0).
            CaseItem(Const(rBaseDec, width: stW), [
              st < Const(rBaseCap, width: stW),
            ]),
            CaseItem(Const(rBaseCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
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
                  brIdxR < Const(0, width: 3),
                  st < Const(rBrDec, width: stW),
                ],
                orElse: [
                  // level[padded(curPos)] captured by the active cc via the
                  // combinational write port (lvlWrEn at rBaseCap, base<=2).
                  st < Const(rNext, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(rBrDec, width: stW), [
              st < Const(rBrCap, width: stW),
            ]),
            CaseItem(Const(rBrCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              levelReg < (levelReg + sym.zeroExtend(8)).getRange(0, 8),
              If(
                sym.lt(Const(3, width: ec.symWidth)) |
                    brIdxR.eq(Const(3, width: 3)),
                then: [
                  // level captured by the active cc write port (lvlWrEn at
                  // rBrCap on the terminating coeff_br).
                  st < Const(rNext, width: stW),
                ],
                orElse: [
                  brIdxR < (brIdxR + Const(1, width: 3)),
                  st < Const(rBrDec, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(rNext, width: stW), [
              If(
                cIdx.eq(Const(0, width: 8)),
                then: [
                  cIdx < Const(0, width: 8),
                  st < Const(rPbCheck, width: stW),
                ],
                orElse: [
                  cIdx < (cIdx - Const(1, width: 8)),
                  st < Const(rBaseDec, width: stW),
                ],
              ),
            ]),
            // phase B forward: signs + golomb (dequant/placement not needed for
            // od_ec sync, the per-symbol rng proves the coefficients).
            CaseItem(Const(rPbCheck, width: stW), [
              pbLevelReg < pbCur.zeroExtend(21),
              If(
                pbCur.eq(Const(0, width: 8)),
                then: [st < Const(rPbNext, width: stW)],
                orElse: [
                  If(
                    isC0c,
                    then: [st < Const(rPbSignDec, width: stW)],
                    orElse: [st < Const(rPbSignLoad, width: stW)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(rPbSignLoad, width: stW), [
              st < Const(rPbSignDec, width: stW),
            ]),
            CaseItem(Const(rPbSignDec, width: stW), [
              st < Const(rPbSignCap, width: stW),
            ]),
            CaseItem(Const(rPbSignCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              csignReg < sym.getRange(0, 1),
              st < Const(rPbGolChk, width: stW),
            ]),
            CaseItem(Const(rPbGolChk, width: stW), [
              If(
                pbLevelReg.gte(Const(15, width: 21)),
                then: [
                  golLeadR < Const(0, width: 6),
                  st < Const(rPbGolLeadLoad, width: stW),
                ],
                orElse: [st < Const(rPbDeq, width: stW)],
              ),
            ]),
            CaseItem(Const(rPbGolLeadLoad, width: stW), [
              st < Const(rPbGolLeadDec, width: stW),
            ]),
            CaseItem(Const(rPbGolLeadDec, width: stW), [
              st < Const(rPbGolLeadCap, width: stW),
            ]),
            CaseItem(Const(rPbGolLeadCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1) | golLeadR.gte(Const(31, width: 6)),
                then: [
                  golXR < Const(1, width: 21),
                  golCntR < Const(0, width: 6),
                  If(
                    golLeadR.eq(Const(0, width: 6)),
                    then: [st < Const(rPbDeq, width: stW)],
                    orElse: [st < Const(rPbGolReadLoad, width: stW)],
                  ),
                ],
                orElse: [
                  golLeadR < (golLeadR + Const(1, width: 6)),
                  st < Const(rPbGolLeadLoad, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(rPbGolReadLoad, width: stW), [
              st < Const(rPbGolReadDec, width: stW),
            ]),
            CaseItem(Const(rPbGolReadDec, width: stW), [
              st < Const(rPbGolReadCap, width: stW),
            ]),
            CaseItem(Const(rPbGolReadCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                (golCntR + Const(1, width: 6)).eq(golLeadR),
                then: [
                  pbLevelReg <
                      (pbLevelReg +
                              ((golXR << 1) |
                                  sym.getRange(0, 1).zeroExtend(21)) -
                              Const(1, width: 21))
                          .getRange(0, 21),
                  st < Const(rPbDeq, width: stW),
                ],
                orElse: [
                  golXR <
                      ((golXR << 1) | sym.getRange(0, 1).zeroExtend(21))
                          .getRange(0, 21),
                  golCntR < (golCntR + Const(1, width: 6)),
                  st < Const(rPbGolReadLoad, width: stW),
                ],
              ),
            ]),
            CaseItem(Const(rPbDeq, width: stW), [
              // accumulate culLevel (cap 63) + capture the DC-coeff sign for EC.
              culLevelReg <
                  mux(
                    (culLevelReg.zeroExtend(21) + pbLevelReg).gt(
                      Const(63, width: 21),
                    ),
                    Const(63, width: 7),
                    (culLevelReg.zeroExtend(21) + pbLevelReg).getRange(0, 7),
                  ),
              If(isC0c, then: [dcValNeg < csignReg, dcValPos < ~csignReg]),
              st < Const(rPbNext, width: stW),
            ]),
            CaseItem(Const(rPbNext, width: stW), [
              If(
                (cIdx + Const(1, width: 8))
                    .getRange(0, 8)
                    .eq(eobReg.getRange(0, 8)),
                then: [
                  // txb done. Luma: pulse eob/tx_type + write luma EC + next leaf.
                  // Chroma: write chroma EC + advance plane (rCEcWrite).
                  If(
                    curPlane.eq(Const(0, width: 2)),
                    then: [
                      resEobReg < eobReg,
                      resTxTypeReg < txTypeReg,
                      resValidReg < Const(1),
                      st < Const(rEcWrite, width: stW),
                    ],
                    orElse: [st < Const(rCEcWrite, width: stW)],
                  ),
                ],
                orElse: [
                  cIdx < (cIdx + Const(1, width: 8)),
                  st < Const(rPbCheck, width: stW),
                ],
              ),
            ]),
            // chroma coeff decode (U then V)
            // txb_skip for the active chroma plane, all-zero -> EC-write 0 + advance,
            // else run the shared coeff FSM (forced tx_type already set).
            CaseItem(Const(rCSkipDec, width: stW), [
              st < Const(rCSkipCap, width: stW),
            ]),
            CaseItem(Const(rCSkipCap, width: stW), [
              symCnt < (symCnt + Const(1, width: 12)),
              symValid < Const(1),
              If(
                sym.getRange(0, 1),
                then: [
                  // all-zero chroma txb: EC-write culLevel 0.
                  culLevelReg < Const(0, width: 7),
                  dcValNeg < Const(0), dcValPos < Const(0),
                  st < Const(rCEcWrite, width: stW),
                ],
                orElse: [st < Const(rEobPtDec, width: stW)],
              ),
            ]),
            CaseItem(Const(rCEcWrite, width: stW), [
              // write the active chroma plane's EC over the txb extent.
              If(
                curPlane.eq(Const(1, width: 2)),
                then: setEntropyCtx(1, curAOff, curLOff),
              ),
              If(
                curPlane.eq(Const(2, width: 2)),
                then: setEntropyCtx(2, curAOff, curLOff),
              ),
              // advance: U -> V (same geometry, forced tx_type, cleared buffers),
              // V -> next luma leaf list done -> sLeaf.
              If(
                curPlane.eq(Const(1, width: 2)),
                then: [
                  curPlane < Const(2, width: 2),
                  curTxSize < rom(_uvTx420, bbs, 5),
                  txTypeReg < blkLumaTxType,
                  txClassReg < rom(_txClass16, blkLumaTxType, 2),
                  culLevelReg < Const(0, width: 7),
                  dcValNeg < Const(0), dcValPos < Const(0),
                  // cc level buffers cleared via lvlClear (rCEcWrite, U->V).
                  st < Const(rCSkipDec, width: stW),
                ],
                orElse: [st < Const(sLeaf, width: stW)],
              ),
            ]),
            CaseItem(Const(sDone, width: stW), [
              If(~input('start'), then: [st < Const(sIdle, width: stW)]),
            ]),
            ...tmvpItems,
          ]),
        ],
      ),
    ]);
  }

  // mode_context (av1_mode_context_analyzer switch on nearestMatch, using the
  // refMatch from accumulated row/col match and the nearest-phase newmv count).
  static List<Conditional> _modeCtx(
    Logic mctx,
    Logic nearestMatch,
    Logic rowMatch,
    Logic colMatch,
    Logic newmv,
    Logic globalMvBit,
  ) {
    final refMatch =
        (rowMatch.gt(Const(0, width: 5)).zeroExtend(2) +
                colMatch.gt(Const(0, width: 5)).zeroExtend(2))
            .getRange(0, 2);
    final nm = newmv.gt(Const(0, width: 5));
    final c0 =
        (mux<Logic>(
                  refMatch.gte(Const(1, width: 2)),
                  Const(1, width: 8),
                  Const(0, width: 8),
                ) |
                mux(
                  refMatch.eq(Const(1, width: 2)),
                  Const(1 << 4, width: 8),
                  mux(
                    refMatch.gte(Const(2, width: 2)),
                    Const(2 << 4, width: 8),
                    Const(0, width: 8),
                  ),
                ))
            .getRange(0, 8);
    final c1 =
        (mux<Logic>(nm, Const(2, width: 8), Const(3, width: 8)) |
                mux(
                  refMatch.eq(Const(1, width: 2)),
                  Const(3 << 4, width: 8),
                  mux(
                    refMatch.gte(Const(2, width: 2)),
                    Const(4 << 4, width: 8),
                    Const(0, width: 8),
                  ),
                ))
            .getRange(0, 8);
    final c2 =
        (mux<Logic>(
                  newmv.gte(Const(1, width: 5)),
                  Const(4, width: 8),
                  Const(5, width: 8),
                ) |
                Const(5 << 4, width: 8))
            .getRange(0, 8);
    return [
      mctx <
          (mux(
                    nearestMatch.eq(Const(0, width: 2)),
                    c0,
                    mux(nearestMatch.eq(Const(1, width: 2)), c1, c2),
                  ) |
                  (globalMvBit.zeroExtend(8) << 3))
              .getRange(0, 8),
    ];
  }

  static Conditional _gotoState(Logic st, int stW, Logic target) =>
      st <
      (target.width >= stW ? target.getRange(0, stW) : target.zeroExtend(stW));

  // predictor computation (placeholder chain, sets predR/predC and, for
  // non-NEW modes, the final mv).
  static List<Conditional> _predictor(
    Logic mode,
    Logic drlIdx,
    Logic count,
    List<Logic> sr,
    List<Logic> sc,
    Logic allowHp,
    Logic forceInt,
    Logic predR,
    Logic predC,
    Logic mvR,
    Logic mvC,
    Logic gmvR,
    Logic gmvC,
    int symW,
  ) {
    Logic sel(List<Logic> a, Logic i) {
      Logic v = a.last;
      for (var k = a.length - 2; k >= 0; k--) {
        v = mux(i.eq(Const(k, width: 4)), a[k], v);
      }
      return v;
    }

    // lower_mv_precision (force_integer_mv / !allow_hp), matching SW
    // _lowerMvPrecision. MUST be a no-op when allow_hp is set (odd MVs kept):
    // rounding unconditionally corrupts every NEAREST/NEAR block's stored MV,
    // which stays invisible to the rng-only compare until a neighbour drl
    // context reads the (wrongly split) ref-mv-stack weights.
    Logic lower(Logic v) {
      final absv = mux(v[15], (Const(0, width: 16) - v).getRange(0, 16), v);
      final aint =
          ((absv + Const(3, width: 16)).getRange(0, 16) &
                  Const(0xFFF8, width: 16))
              .getRange(0, 16);
      final fiRes = mux(
        v[15],
        (Const(0, width: 16) - aint).getRange(0, 16),
        aint,
      );
      final adj = mux(
        v[15],
        (v + Const(1, width: 16)).getRange(0, 16),
        (v - Const(1, width: 16)).getRange(0, 16),
      );
      final hpRes = mux(v[0], adj, v);
      return mux(forceInt, fiRes, mux(allowHp, v, hpRes));
    }

    // av1_find_best_ref_mvs pads empty stack slots with the (lowered) global MV.
    final nearestR = lower(
      mux(count.gt(Const(0, width: 4)), sel(sr, Const(0, width: 4)), gmvR),
    );
    final nearestC = lower(
      mux(count.gt(Const(0, width: 4)), sel(sc, Const(0, width: 4)), gmvC),
    );
    // NEAR: base stack[1] lowered (gm-padded), or stack[1+drl] raw if drl>0.
    final near1R = lower(
      mux(count.gt(Const(1, width: 4)), sel(sr, Const(1, width: 4)), gmvR),
    );
    final near1C = lower(
      mux(count.gt(Const(1, width: 4)), sel(sc, Const(1, width: 4)), gmvC),
    );
    final nearIdx = (Const(1, width: 4) + drlIdx.zeroExtend(4)).getRange(0, 4);
    final nearRawR = sel(sr, nearIdx);
    final nearRawC = sel(sc, nearIdx);
    final nearR = mux(drlIdx.gt(Const(0, width: 3)), nearRawR, near1R);
    final nearC = mux(drlIdx.gt(Const(0, width: 3)), nearRawC, near1C);
    // NEW predictor: stack[drlIdx] raw if count>1 else nearest(lowered).
    final newPR = mux(
      count.gt(Const(1, width: 4)),
      sel(sr, drlIdx.zeroExtend(4)),
      nearestR,
    );
    final newPC = mux(
      count.gt(Const(1, width: 4)),
      sel(sc, drlIdx.zeroExtend(4)),
      nearestC,
    );
    final isNew = mode.eq(Const(16, width: 5));
    final isNearest = mode.eq(Const(13, width: 5));
    final isNear = mode.eq(Const(14, width: 5));
    return [
      predR < mux(isNew, newPR, Const(0, width: 16)),
      predC < mux(isNew, newPC, Const(0, width: 16)),
      // finalize mv for non-NEW modes: GLOBALMV uses the raw (unlowered) gmv.
      mvR < mux(isNearest, nearestR, mux(isNear, nearR, gmvR)),
      mvC < mux(isNearest, nearestC, mux(isNear, nearC, gmvC)),
    ];
  }

  // block-extent predicate: (i,j) in [br,br+bh4) x [bc,bc+bw4)
  static Logic _inBlock(
    Logic i,
    Logic j,
    Logic r,
    Logic c,
    Logic bw4,
    Logic bh4,
  ) {
    final ri =
        i.gte(r) & i.lt((r.zeroExtend(6) + bh4).getRange(0, 6).getRange(0, 5));
    final cj =
        j.gte(c) & j.lt((c.zeroExtend(6) + bw4).getRange(0, 6).getRange(0, 5));
    return ri & cj;
  }

  static Logic _inSpan(Logic i, Logic base, Logic span) {
    return i.gte(base) &
        i.lt((base.zeroExtend(6) + span).getRange(0, 6).getRange(0, 5));
  }
}
