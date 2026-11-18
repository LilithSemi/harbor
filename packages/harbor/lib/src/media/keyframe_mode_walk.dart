import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import 'av1_cdf_tables.dart' as cdf;
import 'coeff_context.dart';
import 'dequant.dart';
import 'od_ec_decoder.dart';
import 'palette_color_context.dart';

/// Harbor bit-exact AV1 keyframe partition + mode-info walk for ONE fully
/// interior superblock on a SINGLE shared od_ec window (the second slice of the
/// tile-assembly FSM, layered on [partition_tree_walk]).
///
/// Extends the partition recursion so that at EACH leaf it also decodes the
/// monochrome-keyframe mode info on the same window: block_skip (ctx from the
/// above/left skip arrays), intra_frame_y_mode (kf ctx from the above/left
/// y_mode arrays through Intra_Mode_Context), and angle_delta_y when the block
/// is >= 8x8 and the mode is directional. It maintains the cross-block neighbour
/// arrays (partition ctx + skip + y_mode) exactly as `_decodeBlock`. All entropy
/// contexts (16 partition + 3 skip + 25 kf-y-mode + 8 angle-delta = 52) are
/// preloaded ONCE and ADAPT across the whole walk, matching a real tile.
///
/// Coefficients / reconstruction are NOT decoded here (that is the next slice).
/// A leaf consumes only its mode-info bits. Verification surface: `leaf_count`,
/// `sym_count`, a running `chk` over (r,c,bsize,skip,y_mode,angle) per leaf, and
/// the final above/left partition-ctx + skip + y_mode arrays.
class HarborKeyframeModeWalk extends BridgeModule {
  /// Maximum coded bytes the internal buffer holds.
  final int maxBytes;

  /// Root (superblock) block size, square BLOCK_16X16 = 6 / 32X32 = 9 / 64X64.
  final int rootBsize;

  static const _miWide = [
    1,
    1,
    2,
    2,
    2,
    4,
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
    1,
    4,
    2,
    8,
    4,
    16,
  ];
  static const _miHigh = [
    1,
    2,
    1,
    2,
    4,
    2,
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
    4,
    1,
    8,
    2,
    16,
    4,
  ];
  static const _miWideLog2 = [
    0,
    0,
    1,
    1,
    1,
    2,
    2,
    2,
    3,
    3,
    3,
    4,
    4,
    4,
    5,
    5,
    0,
    2,
    1,
    3,
    2,
    4,
  ];
  static const _partCtxAbove = [
    31,
    31,
    30,
    30,
    30,
    28,
    28,
    28,
    24,
    24,
    24,
    16,
    16,
    16,
    0,
    0,
    31,
    28,
    30,
    24,
    28,
    16,
  ];
  static const _partCtxLeft = [
    31,
    30,
    31,
    30,
    28,
    30,
    28,
    24,
    28,
    24,
    16,
    24,
    16,
    0,
    16,
    0,
    28,
    31,
    24,
    30,
    16,
    28,
  ];
  static const _psub = [
    3, 2, 1, 0, 0, 0, 0, 0, 0, 0, //
    6, 5, 4, 3, 5, 5, 4, 4, 17, 16, //
    9, 8, 7, 6, 8, 8, 7, 7, 19, 18, //
    12, 11, 10, 9, 11, 11, 10, 10, 21, 20,
  ];
  static const _intraModeContext = [0, 1, 2, 3, 4, 4, 4, 4, 3, 0, 1, 2, 0];
  // palette bsize ctx = num_pels_log2(bsize) - num_pels_log2(BLOCK_8X8=6),
  // indexed by block-size enum. Palette only applies to 8x8..64x64 so the
  // sub-8x8 entries (0..2) are don't-care (clamped to 0).
  static const _palBsizeCtx = [
    0,
    0,
    0,
    0,
    1,
    1,
    2,
    3,
    3,
    4,
    5,
    5,
    6,
    6,
    6,
    6,
    0,
    0,
    2,
    2,
    4,
    4,
  ];
  // default_angle_delta_cdf (ICDF), 8 directional modes x 7 syms.
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
  // default_filter_intra_cdfs[BLOCK_SIZES_ALL=22][2] (ICDF, each row [32768-a, 0],
  // a from libaom entropymode.c). Indexed by block-size enum, the 2-sym
  // use_filter_intra CDF.
  static const _filterIntraCdf = [
    [28147, 0],
    [26025, 0],
    [26875, 0],
    [24902, 0],
    [20217, 0],
    [23374, 0],
    [20360, 0],
    [18467, 0],
    [20012, 0],
    [10425, 0],
    [16384, 0],
    [16384, 0],
    [16384, 0],
    [16384, 0],
    [16384, 0],
    [16384, 0],
    [19998, 0],
    [22400, 0],
    [12539, 0],
    [14667, 0],
    [16384, 0],
    [16384, 0],
  ];
  // default_filter_intra_mode_cdf[FILTER_INTRA_MODES=5] (ICDF), 5-sym.
  static const _filterIntraModeCdf = [23819, 19992, 15557, 3210, 0];
  // fimode_to_intradir[FILTER_INTRA_MODES] -> intra dir used for the ext-tx CDF
  // context when filter_intra is active: DC, V, H, D157, DC.
  static const _fimodeToIntradir = [0, 1, 2, 6, 0];
  // PALETTE default CDFs (forward AOM_CDFn args from libaom entropymode.c,
  // converted to ICDF in the constructor). Only used when enablePalette.
  // default_palette_y_size_cdf[PALATTE_BSIZE_CTXS=7][CDF_SIZE(PALETTE_SIZES=7)].
  static const _palYSizeFwd = [
    [7952, 13000, 18149, 21478, 25527, 29241],
    [7139, 11421, 16195, 19544, 23666, 28073],
    [7788, 12741, 17325, 20500, 24315, 28530],
    [8271, 14064, 18246, 21564, 25071, 28533],
    [12725, 19180, 21863, 24839, 27535, 30120],
    [9711, 14888, 16923, 21052, 25661, 27875],
    [14940, 20797, 21678, 24186, 27033, 28999],
  ];
  // default_palette_uv_size_cdf[7][CDF_SIZE(7)].
  static const _palUVSizeFwd = [
    [8713, 19979, 27128, 29609, 31331, 32272],
    [5839, 15573, 23581, 26947, 29848, 31700],
    [4426, 11260, 17999, 21483, 25863, 29430],
    [3228, 9464, 14993, 18089, 22523, 27420],
    [3768, 8886, 13091, 17852, 22495, 27207],
    [2464, 8451, 12861, 21632, 25525, 28555],
    [1269, 5435, 10433, 18963, 21700, 25865],
  ];
  // default_palette_y_mode_cdf[7][PALETTE_Y_MODE_CONTEXTS=3][CDF_SIZE(2)].
  static const _palYModeFwd = [
    [31676, 3419, 1261],
    [31912, 2859, 980],
    [31823, 3400, 781],
    [32030, 3561, 904],
    [32309, 7337, 1462],
    [32265, 4015, 1521],
    [32450, 7946, 129],
  ];
  // default_palette_uv_mode_cdf[PALETTE_UV_MODE_CONTEXTS=2][CDF_SIZE(2)].
  static const _palUVModeFwd = [32461, 21488];
  // default_palette_y_color_index_cdf[PALETTE_SIZES=7][COLOR_CONTEXTS=5]
  // [CDF_SIZE(size)] (row s => nsyms = s+2).
  static const _palYColorFwd = [
    [
      [28710],
      [16384],
      [10553],
      [27036],
      [31603],
    ],
    [
      [27877, 30490],
      [11532, 25697],
      [6544, 30234],
      [23018, 28072],
      [31915, 32385],
    ],
    [
      [25572, 28046, 30045],
      [9478, 21590, 27256],
      [7248, 26837, 29824],
      [19167, 24486, 28349],
      [31400, 31825, 32250],
    ],
    [
      [24779, 26955, 28576, 30282],
      [8669, 20364, 24073, 28093],
      [4255, 27565, 29377, 31067],
      [19864, 23674, 26716, 29530],
      [31646, 31893, 32147, 32426],
    ],
    [
      [23132, 25407, 26970, 28435, 30073],
      [7443, 17242, 20717, 24762, 27982],
      [6300, 24862, 26944, 28784, 30671],
      [18916, 22895, 25267, 27435, 29652],
      [31270, 31550, 31808, 32059, 32353],
    ],
    [
      [23105, 25199, 26464, 27684, 28931, 30318],
      [6950, 15447, 18952, 22681, 25567, 28563],
      [7560, 23474, 25490, 27203, 28921, 30708],
      [18544, 22373, 24457, 26195, 28119, 30045],
      [31198, 31451, 31670, 31882, 32123, 32391],
    ],
    [
      [21689, 23883, 25163, 26352, 27506, 28827, 30195],
      [6892, 15385, 17840, 21606, 24287, 26753, 29204],
      [5651, 23182, 25042, 26518, 27982, 29392, 30900],
      [19349, 22578, 24418, 25994, 27524, 29031, 30448],
      [31028, 31270, 31504, 31705, 31927, 32153, 32392],
    ],
  ];
  // default_palette_uv_color_index_cdf[7][5][CDF_SIZE(size)].
  static const _palUVColorFwd = [
    [
      [29089],
      [16384],
      [8713],
      [29257],
      [31610],
    ],
    [
      [25257, 29145],
      [12287, 27293],
      [7033, 27960],
      [20145, 25405],
      [30608, 31639],
    ],
    [
      [24210, 27175, 29903],
      [9888, 22386, 27214],
      [5901, 26053, 29293],
      [18318, 22152, 28333],
      [30459, 31136, 31926],
    ],
    [
      [22980, 25479, 27781, 29986],
      [8413, 21408, 24859, 28874],
      [2257, 29449, 30594, 31598],
      [19189, 21202, 25915, 28620],
      [31844, 32044, 32281, 32518],
    ],
    [
      [22217, 24567, 26637, 28683, 30548],
      [7307, 16406, 19636, 24632, 28424],
      [4441, 25064, 26879, 28942, 30919],
      [17210, 20528, 23319, 26750, 29582],
      [30674, 30953, 31396, 31735, 32207],
    ],
    [
      [21239, 23168, 25044, 26962, 28705, 30506],
      [6545, 15012, 18004, 21817, 25503, 28701],
      [3448, 26295, 27437, 28704, 30126, 31442],
      [15889, 18323, 21704, 24698, 26976, 29690],
      [30988, 31204, 31479, 31734, 31983, 32325],
    ],
    [
      [21442, 23288, 24758, 26246, 27649, 28980, 30563],
      [5863, 14933, 17552, 20668, 23683, 26411, 29273],
      [3415, 25810, 26877, 27990, 29223, 30394, 31618],
      [17965, 20084, 22232, 23974, 26274, 28402, 30390],
      [31190, 31329, 31516, 31679, 31825, 32026, 32322],
    ],
  ];
  // av1_palette_color_index_context_lookup (unused here, ctx via submodule).
  // kIntraExtTxCdf[1][0][mode], TX_4X4 (per-y_mode ext-tx) + inverse map.
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
  static const _extTxInv = [9, 0, 10, 11, 3, 1, 2];
  // TX_16X16 DTT4_IDTX inverse map (sym -> tx_type, all 2D).
  static const _extTxInv16 = [9, 0, 3, 1, 2];
  static const _eobOffsetBits = [0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
  static const _eobGroupStart = [0, 1, 2, 3, 5, 9, 17, 33, 65, 129, 257, 513];
  // libaom skip_contexts[top][left] (top/left clamped 0..4), flat row-major 5x5.
  // Used by the tx-split (depth 1) sub-blocks where planeBsize (8x8) != tx
  // (4x4) so the txb_skip ctx is neighbour-derived, NOT 0.
  static const _txbSkipCtx = [
    1, 2, 2, 2, 3, //
    2, 4, 4, 4, 5, //
    2, 4, 4, 4, 5, //
    2, 4, 4, 4, 5, //
    3, 5, 5, 5, 6,
  ];
  // TX_4X4 scans by class: 2D / VERT (mrow) / HORIZ (mcol).
  static const _scan4 = [0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15];
  static const _mrow4 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
  static const _mcol4 = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
  // TX_8X8 scans by class: 2D (default) / VERT (mrow) / HORIZ (mcol).
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
  // ext-tx by intra y_mode at TX_8X8 (kIntraExtTxCdf[1][1][mode]).
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
  // ext-tx by intra y_mode at TX_16X16 (kIntraExtTxCdf[2][2][mode], DTT4_IDTX,
  // 5-sym, all 2D). inverse map _extTxInv16 = [9,0,3,1,2].
  static const _extTxByMode16 = [
    [31641, 19954, 9996, 5285, 0],
    [32623, 26007, 20788, 6101, 0],
    [32406, 26881, 21090, 16043, 0],
    [32383, 17555, 14181, 2075, 0],
    [32743, 29854, 9634, 4865, 0],
    [32708, 28298, 21019, 8777, 0],
    [32731, 29436, 18257, 11320, 0],
    [32611, 26448, 19732, 15329, 0],
    [32649, 26049, 19862, 3372, 0],
    [32721, 27231, 20192, 11269, 0],
    [32499, 26692, 21510, 9653, 0],
    [32685, 27153, 20767, 15540, 0],
    [30800, 27212, 20745, 14221, 0],
  ];
  // default_scan_16x16 (TX_16X16, 2D).
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
  // default_scan_32x32 (TX_32X32 / TX_64X64 coeff region, 2D).
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
  // Rect TX_8X4 (HORZ sub-block, n=32, bhl=2) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan8x4 = [
    0, 1, 4, 2, 5, 8, 3, 6, 9, 12, 7, 10, 13, 16, 11, 14, //
    17, 20, 15, 18, 21, 24, 19, 22, 25, 28, 23, 26, 29, 27, 30, 31,
  ];
  static const _mrow8x4 = [
    0, 4, 8, 12, 16, 20, 24, 28, 1, 5, 9, 13, 17, 21, 25, 29, //
    2, 6, 10, 14, 18, 22, 26, 30, 3, 7, 11, 15, 19, 23, 27, 31,
  ];
  static const _mcol8x4 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  ];
  // Rect TX_4X8 (VERT sub-block, n=32, bhl=3) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan4x8 = [
    0, 8, 1, 16, 9, 2, 24, 17, 10, 3, 25, 18, 11, 4, 26, 19, //
    12, 5, 27, 20, 13, 6, 28, 21, 14, 7, 29, 22, 15, 30, 23, 31,
  ];
  static const _mrow4x8 = [
    0, 8, 16, 24, 1, 9, 17, 25, 2, 10, 18, 26, 3, 11, 19, 27, //
    4, 12, 20, 28, 5, 13, 21, 29, 6, 14, 22, 30, 7, 15, 23, 31,
  ];
  static const _mcol4x8 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
  ];
  // Rect TX_16X8 (n=128, bhl=3) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan16x8 = [
    0, 1, 8, 2, 9, 16, 3, 10, 17, 24, 4, 11, 18, 25, 32, 5, //
    12, 19, 26, 33, 40, 6, 13, 20, 27, 34, 41, 48, 7, 14, 21, 28, //
    35, 42, 49, 56, 15, 22, 29, 36, 43, 50, 57, 64, 23, 30, 37, 44, //
    51, 58, 65, 72, 31, 38, 45, 52, 59, 66, 73, 80, 39, 46, 53, 60, //
    67, 74, 81, 88, 47, 54, 61, 68, 75, 82, 89, 96, 55, 62, 69, 76, //
    83, 90, 97, 104, 63, 70, 77, 84, 91, 98, 105, 112, 71, 78, 85, 92, //
    99, 106, 113, 120, 79, 86, 93, 100, 107, 114, 121, 87, 94, 101, 108, 115, //
    122,
    95,
    102,
    109,
    116,
    123,
    103,
    110,
    117,
    124,
    111,
    118,
    125,
    119,
    126,
    127,
  ];
  static const _mrow16x8 = [
    0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, //
    1, 9, 17, 25, 33, 41, 49, 57, 65, 73, 81, 89, 97, 105, 113, 121, //
    2, 10, 18, 26, 34, 42, 50, 58, 66, 74, 82, 90, 98, 106, 114, 122, //
    3, 11, 19, 27, 35, 43, 51, 59, 67, 75, 83, 91, 99, 107, 115, 123, //
    4, 12, 20, 28, 36, 44, 52, 60, 68, 76, 84, 92, 100, 108, 116, 124, //
    5, 13, 21, 29, 37, 45, 53, 61, 69, 77, 85, 93, 101, 109, 117, 125, //
    6, 14, 22, 30, 38, 46, 54, 62, 70, 78, 86, 94, 102, 110, 118, 126, //
    7, 15, 23, 31, 39, 47, 55, 63, 71, 79, 87, 95, 103, 111, 119, 127,
  ];
  static const _mcol16x8 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, //
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, //
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, //
    96,
    97,
    98,
    99,
    100,
    101,
    102,
    103,
    104,
    105,
    106,
    107,
    108,
    109,
    110,
    111, //
    112,
    113,
    114,
    115,
    116,
    117,
    118,
    119,
    120,
    121,
    122,
    123,
    124,
    125,
    126,
    127,
  ];
  // Rect TX_8X16 (n=128, bhl=4) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan8x16 = [
    0, 16, 1, 32, 17, 2, 48, 33, 18, 3, 64, 49, 34, 19, 4, 80, //
    65, 50, 35, 20, 5, 96, 81, 66, 51, 36, 21, 6, 112, 97, 82, 67, //
    52, 37, 22, 7, 113, 98, 83, 68, 53, 38, 23, 8, 114, 99, 84, 69, //
    54, 39, 24, 9, 115, 100, 85, 70, 55, 40, 25, 10, 116, 101, 86, 71, //
    56, 41, 26, 11, 117, 102, 87, 72, 57, 42, 27, 12, 118, 103, 88, 73, //
    58, 43, 28, 13, 119, 104, 89, 74, 59, 44, 29, 14, 120, 105, 90, 75, //
    60, 45, 30, 15, 121, 106, 91, 76, 61, 46, 31, 122, 107, 92, 77, 62, //
    47, 123, 108, 93, 78, 63, 124, 109, 94, 79, 125, 110, 95, 126, 111, 127,
  ];
  static const _mrow8x16 = [
    0, 16, 32, 48, 64, 80, 96, 112, 1, 17, 33, 49, 65, 81, 97, 113, //
    2, 18, 34, 50, 66, 82, 98, 114, 3, 19, 35, 51, 67, 83, 99, 115, //
    4, 20, 36, 52, 68, 84, 100, 116, 5, 21, 37, 53, 69, 85, 101, 117, //
    6, 22, 38, 54, 70, 86, 102, 118, 7, 23, 39, 55, 71, 87, 103, 119, //
    8, 24, 40, 56, 72, 88, 104, 120, 9, 25, 41, 57, 73, 89, 105, 121, //
    10, 26, 42, 58, 74, 90, 106, 122, 11, 27, 43, 59, 75, 91, 107, 123, //
    12, 28, 44, 60, 76, 92, 108, 124, 13, 29, 45, 61, 77, 93, 109, 125, //
    14, 30, 46, 62, 78, 94, 110, 126, 15, 31, 47, 63, 79, 95, 111, 127,
  ];
  static const _mcol8x16 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, //
    64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, //
    80, 81, 82, 83, 84, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, //
    96,
    97,
    98,
    99,
    100,
    101,
    102,
    103,
    104,
    105,
    106,
    107,
    108,
    109,
    110,
    111, //
    112,
    113,
    114,
    115,
    116,
    117,
    118,
    119,
    120,
    121,
    122,
    123,
    124,
    125,
    126,
    127,
  ];
  // Rect TX_4X16 (n=64, bhl=4) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan4x16 = [
    0, 16, 1, 32, 17, 2, 48, 33, 18, 3, 49, 34, 19, 4, 50, 35, //
    20, 5, 51, 36, 21, 6, 52, 37, 22, 7, 53, 38, 23, 8, 54, 39, //
    24, 9, 55, 40, 25, 10, 56, 41, 26, 11, 57, 42, 27, 12, 58, 43, //
    28, 13, 59, 44, 29, 14, 60, 45, 30, 15, 61, 46, 31, 62, 47, 63,
  ];
  static const _mrow4x16 = [
    0, 16, 32, 48, 1, 17, 33, 49, 2, 18, 34, 50, 3, 19, 35, 51, //
    4, 20, 36, 52, 5, 21, 37, 53, 6, 22, 38, 54, 7, 23, 39, 55, //
    8, 24, 40, 56, 9, 25, 41, 57, 10, 26, 42, 58, 11, 27, 43, 59, //
    12, 28, 44, 60, 13, 29, 45, 61, 14, 30, 46, 62, 15, 31, 47, 63,
  ];
  static const _mcol4x16 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  ];
  // Rect TX_16X4 (n=64, bhl=2) scans: 2D / VERT(mrow) / HORIZ(mcol).
  static const _scan16x4 = [
    0, 1, 4, 2, 5, 8, 3, 6, 9, 12, 7, 10, 13, 16, 11, 14, //
    17, 20, 15, 18, 21, 24, 19, 22, 25, 28, 23, 26, 29, 32, 27, 30, //
    33, 36, 31, 34, 37, 40, 35, 38, 41, 44, 39, 42, 45, 48, 43, 46, //
    49, 52, 47, 50, 53, 56, 51, 54, 57, 60, 55, 58, 61, 59, 62, 63,
  ];
  static const _mrow16x4 = [
    0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, //
    1, 5, 9, 13, 17, 21, 25, 29, 33, 37, 41, 45, 49, 53, 57, 61, //
    2, 6, 10, 14, 18, 22, 26, 30, 34, 38, 42, 46, 50, 54, 58, 62, //
    3, 7, 11, 15, 19, 23, 27, 31, 35, 39, 43, 47, 51, 55, 59, 63,
  ];
  static const _mcol16x4 = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, //
    16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, //
    32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, //
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
  ];

  // CfL CDFs (ICDF: row = [32768-x ..] + [0]). default_cfl_sign_cdf and
  // default_cfl_alpha_cdf[CFL_ALPHA_CONTEXTS=6][CFL_ALPHABET_SIZE=16].
  static List<int> _icCfl(List<int> fwd) => [for (final x in fwd) 32768 - x, 0];
  static final List<int> _cflSignCdf = _icCfl([
    1418,
    2123,
    13340,
    18405,
    26972,
    28343,
    32294,
  ]);
  static final List<List<int>> _cflAlphaCdf = [
    _icCfl([
      7637,
      20719,
      31401,
      32481,
      32657,
      32688,
      32692,
      32696,
      32700,
      32704,
      32708,
      32712,
      32716,
      32720,
      32724,
    ]),
    _icCfl([
      14365,
      23603,
      28135,
      31168,
      32167,
      32395,
      32487,
      32573,
      32620,
      32647,
      32668,
      32672,
      32676,
      32680,
      32684,
    ]),
    _icCfl([
      11532,
      22380,
      28445,
      31360,
      32349,
      32523,
      32584,
      32649,
      32673,
      32677,
      32681,
      32685,
      32689,
      32693,
      32697,
    ]),
    _icCfl([
      26990,
      31402,
      32282,
      32571,
      32692,
      32696,
      32700,
      32704,
      32708,
      32712,
      32716,
      32720,
      32724,
      32728,
      32732,
    ]),
    _icCfl([
      17248,
      26058,
      28904,
      30608,
      31305,
      31877,
      32126,
      32321,
      32394,
      32464,
      32516,
      32560,
      32576,
      32593,
      32622,
    ]),
    _icCfl([
      14738,
      21678,
      25779,
      27901,
      29024,
      30302,
      30980,
      31843,
      32144,
      32413,
      32520,
      32594,
      32622,
      32656,
      32660,
    ]),
  ];
  // uv intra mode -> luma intra mode (identity 0..12, 13 UV_CFL_PRED -> DC=0),
  // for the angle_delta_uv directional test.
  static const _uv2y = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0];

  /// When set, each non-skip leaf ALSO decodes the coeff prefix (txb_skip +
  /// ext-tx selected by y_mode) on the same shared window, folding the decoded
  /// `all_zero` / `tx_type` into the checksum. The first slice of the full
  /// coeff merge (4x4 luma). Also permits an 8x8 superblock root.
  final bool coeffPrefix;

  /// Base-qindex CDF set (0..3) for the coeff tables (coeffPrefix). The
  /// partition/skip/y_mode/angle/ext-tx CDFs are not qindex-banded.
  final int qband;

  /// When set (with [coeffPrefix] and an 8x8 root), the per-leaf coeff decode
  /// becomes VARIABLE-SIZE: a NONE-partition 8x8 leaf (BLOCK_8X8) additionally
  /// decodes a `tx_size` depth symbol and, for depth 0 (TX_8X8), its luma coeffs
  /// as ONE 64-coefficient transform block on the same shared od_ec window
  /// (`_readTxSize` + `read_coeffs_txb` at TX_8X8, libaom-exact). The existing
  /// 4x4 leaves (a SPLIT 8x8 root, or any sub-8x8 leaf) are UNCHANGED. Adds the
  /// `leaf_log2size` output and widens `leaf_coeffs` to 64 coeffs per leaf.
  ///
  /// Depth 1 (the tx-split case) is ALSO supported: the 8x8 luma block is tiled
  /// into FOUR TX_4X4 transform blocks in raster order ((0,0),(0,4),(4,0),(4,4))
  /// decoded consecutively on the same shared od_ec window. Each sub-block reads
  /// its txb_skip / dc_sign context from the WITHIN-LEAF neighbour-EC arrays
  /// (`subAboveEC`/`subLeftEC`, 4x4-tx granularity over the 8x8 leaf) which the
  /// earlier sub-blocks update (matching libaom's `_getTxbCtx`/`_setEntropyCtx`).
  /// CRUX: because planeBsize (BLOCK_8X8) != txsizeToBsize[TX_4X4] (BLOCK_4X4),
  /// the txb_skip ctx is NEIGHBOUR-derived (skipCtx 0..6 via the libaom
  /// skip_contexts table), NOT 0, the first sub-block (no neighbours) still gets
  /// skipCtx 1 (= skip_contexts[0][0]). The four 4x4 coeff blocks are placed into
  /// the leaf's 64-entry coeff slot at their raster offsets. The per-leaf
  /// `leaf_tx_depth` output (0 = TX_8X8, 1 = four TX_4X4) lets recon map a
  /// depth-1 leaf to four 4x4 recon blocks sharing the leaf's y_mode. The
  /// above/left txfm-size context arrays are maintained for `_txSizeContext`.
  final bool txLeaf;

  /// When set (requires [coeffPrefix], [txLeaf] and an 8x8 root), the NONE 8x8
  /// leaf ALSO decodes the 4:2:0 chroma syntax on the same shared od_ec window,
  /// in the exact libaom stream order: after y_mode/angle_delta_y and BEFORE
  /// tx_size it reads uv_mode (14-sym, cflAllowed), cfl_alphas (when
  /// uv_mode == UV_CFL_PRED), and angle_delta_uv (when the uv intra mode is
  /// directional), after the luma TX_8X8 coefficients it reads the U then the V
  /// chroma transform block, each ONE TX_4X4 (planeType 1). Emits the new
  /// `leaf_uv_mode`, `leaf_cfl_alpha_idx`, `leaf_cfl_signs`, `leaf_u_coeffs`
  /// (16x16b) and `leaf_v_coeffs` (16x16b) outputs and folds the chroma decode
  /// into the existing per-leaf checksum is NOT done (the monochrome chk is kept
  /// byte-identical, the chroma data is verified through the new outputs).
  ///
  /// Scope: the NONE 8x8 leaf in 4:2:0 only. The sub-8x8 SPLIT case (where a
  /// chroma-ref block owns the chroma of its collocated luma region) is a
  /// follow-up. With [chroma] false the module is byte-identical to before.
  final bool chroma;

  /// When set (with [chroma], [txLeaf], [tx16] via `maxTxN>=256`, and a 32x32 /
  /// 64x64 root), the per-leaf 4:2:0 chroma is decoded as ONE TX_8X8 per plane
  /// (the collocated chroma of a 16x16 luma leaf) for EVERY leaf, in the exact
  /// libaom bitstream order, and emitted through the per-leaf `leaf_uv_modes` /
  /// `leaf_cfl_alpha_idxs` / `leaf_cfl_signs_arr` / `leaf_u_coeffs_arr` /
  /// `leaf_v_coeffs_arr` arrays. This is the MULTI-LEAF 4:2:0 case (a 64x64 SB
  /// uniformly split into sixteen 16x16 leaves, each a chroma reference). It
  /// reuses the same TX_8X8 chroma machinery as the single-16x16-root `chroma8`
  /// path (levels8/cc8/scan8 + the plane-1 TX_8X8 CDF banks), now enabled for a
  /// bigger root. Requires uniform 16x16 leaves (all chroma TX_8X8), a mixed-leaf
  /// or sub-8x8 partition is out of scope. Default false => byte-identical.
  final bool chromaLeaf16;

  /// Chroma subsampling in X / Y (libaom `subsampling_x` / `subsampling_y`).
  /// (1,1) = 4:2:0 (default, byte-identical), (0,0) = 4:4:4, (1,0) = 4:2:2.
  /// Under [chromaLeaf16] this parameterises the per-leaf chroma TX geometry: a
  /// 16x16 luma leaf has a (16>>ssx) x (16>>ssy) chroma block per plane, i.e.
  /// TX_8X8 at 4:2:0, TX_16X16 at 4:4:4, TX_8X16 at 4:2:2. It also sets the
  /// intra-SB chroma EC neighbour granularity (chroma 4x4 units = luma mi >> ss)
  /// and span (chroma tx dim / 4 units per side).
  final int ssx;
  final int ssy;

  /// When set, the module gains the multi-superblock continuation ports
  /// (`cont` / `above_open`, Increment 1). With it false (the default) those
  /// ports are NOT created and the walk is byte-identical to the original
  /// single-SB module, so existing single-SB tests need no change.
  final bool multiSb;

  /// Tile WIDTH in MI units for the ABOVE-context arrays (Increment 2). The
  /// above-* context arrays (partition ctx + skip + ymode + EC + txfm) span the
  /// whole tile width and are indexed by ABSOLUTE MI column (`sb_c_mi` + the
  /// leaf's local column), so a tile wider than one superblock can keep each
  /// top-row SB's above context in its own column band without overwriting its
  /// left neighbour's. The default (`0`) means "use the root SB width" (= sbMi),
  /// which keeps the arrays root-width and `sb_c_mi` defaulting to 0, so the
  /// single-SB module and the 2-SB pair wrappers are byte-identical to before.
  /// Only honoured with [multiSb] (the absolute-col `sb_c_mi` port exists then).
  /// The LEFT-* arrays always stay root-HEIGHT (indexed by local MI row).
  final int tileMiW;

  /// Max coefficients per leaf (64 = TX_8X8 ceiling, 256 enables TX_16X16
  /// leaves).
  final int maxTxN;

  /// Max leaves emitted (output-buffer depth). 4 covers an 8x8/16x16 root.
  /// Larger roots that split to small leaves need more (32x32->16, 64x64->64).
  final int maxLeafOut;

  /// Frame TX_MODE. When true (TX_MODE_SELECT, the default) a tx-signaling leaf
  /// (BLOCK_8X8 / rect / 16x16 / 32x32 / 64x64, non-skip) reads a `tx_size`
  /// depth symbol on the shared window, exactly as `_readTxSize`. When false
  /// (TX_MODE_LARGEST) the tx size is INFERRED as the largest for the block
  /// (depth 0) and NO `tx_size` symbol is coded, so the leaf must NOT decode one:
  /// reading a phantom symbol would desync every subsequent leaf. Real aomenc
  /// all-intra keyframes are commonly TX_MODE_LARGEST, so this must match the
  /// frame header's tx_mode. (TX_MODE_ONLY_4X4, which forces TX_4X4 rather than
  /// the largest, is not modelled here: the depth-0/largest inference assumes
  /// LARGEST, matching the streams in scope.)
  final bool txModeSelect;

  /// Sequence-header `enable_filter_intra`. When true, an eligible luma leaf
  /// (y_mode == DC_PRED, both block dims <= 32, no palette) codes
  /// `use_filter_intra` (1 bit) and, if set, `filter_intra_mode` (0..4) in the
  /// exact SW bitstream position (after the chroma mode info, before tx_size).
  /// When false NO filter_intra symbol is read, so the stream is byte-identical
  /// to the pre-filter-intra walk (all prior repros).
  final bool enableFilterIntra;

  /// Frame-header `allow_screen_content_tools` -> palette. When true, an eligible
  /// leaf (8x8..64x64, y_mode == DC on luma / uv_mode == DC on chroma) codes
  /// `palette_mode_info` (has_palette_y/uv + sizes + colors via the neighbour
  /// colour cache) after the chroma mode info, and the color-index-map tokens
  /// (`palette_tokens`) before tx_size: the exact SW bitstream positions.
  /// Palette on luma suppresses filter_intra. When false NO palette symbol is
  /// read, so the stream is byte-identical to the pre-palette walk.
  final bool enablePalette;

  /// Sample bit depth (8/10/12). Selects the dc/ac dequant clamp width in the
  /// per-coefficient [HarborDequant] (bd 10 uses the 10-bit qlookup, driven in
  /// as data) and widens the per-leaf coeff storage / `leaf_coeffs` output to
  /// `bitDepth + 8` bits (the signed dequantized-level range). Defaults to 8
  /// (byte-identical: 16-bit coeff slots, the historic width).
  final int bitDepth;

  HarborKeyframeModeWalk({
    this.rootBsize = 6,
    this.maxBytes = 48,
    this.coeffPrefix = false,
    this.qband = 0,
    this.txLeaf = false,
    this.chroma = false,
    this.chromaLeaf16 = false,
    this.ssx = 1,
    this.ssy = 1,
    this.multiSb = false,
    this.tileMiW = 0,
    this.maxLeafOut = 4,
    this.maxTxN = 64,
    this.txModeSelect = true,
    this.enableFilterIntra = false,
    this.enablePalette = false,
    this.bitDepth = 8,
    String? name,
  }) : assert(qband >= 0 && qband < 4, 'qband 0..3'),
       assert(bitDepth == 8 || bitDepth == 10 || bitDepth == 12, 'bit depth'),
       assert(
         tileMiW == 0 || multiSb,
         'tileMiW (tile-width above ctx) requires multiSb',
       ),
       assert(
         rootBsize == 6 ||
             rootBsize == 9 ||
             rootBsize == 12 ||
             (coeffPrefix && rootBsize == 3),
         'root 16x16 / 32x32 / 64x64 (or 8x8 with coeffPrefix)',
       ),
       assert(
         !txLeaf ||
             (coeffPrefix &&
                 (rootBsize == 3 ||
                     rootBsize == 6 ||
                     rootBsize == 9 ||
                     rootBsize == 12)),
         'txLeaf requires coeffPrefix and an 8x8/16x16/32x32/64x64 root',
       ),
       assert(
         !chroma ||
             (coeffPrefix &&
                 txLeaf &&
                 (rootBsize == 3 ||
                     rootBsize == 6 ||
                     rootBsize == 9 ||
                     rootBsize == 12)),
         'chroma requires coeffPrefix, txLeaf and an 8x8/16x16/32x32/64x64 '
         'root (a 64x64 root without chromaLeaf16 uses the base TX_4X4 chroma '
         'geometry, valid only for its FIRST leaf, which has no chroma '
         'neighbour - used by the palette-UV leaf-0 verification)',
       ),
       assert(
         !chromaLeaf16 || (chroma && maxTxN >= 256),
         'chromaLeaf16 requires chroma and tx16 (maxTxN>=256)',
       ),
       assert(
         (ssx == 1 && ssy == 1) ||
             (ssx == 0 && ssy == 0) ||
             (ssx == 1 && ssy == 0),
         'subsampling (ssx,ssy) must be 4:2:0 (1,1), 4:4:4 (0,0) or '
         '4:2:2 (1,0)',
       ),
       assert(
         (ssx == 1 && ssy == 1) || chromaLeaf16,
         'non-4:2:0 subsampling requires the chromaLeaf16 per-leaf chroma '
         'path',
       ),
       super(
         'HarborKeyframeModeWalk',
         name: name ?? 'keyframe_mode_walk_$rootBsize',
       ) {
    final sbMi = _miWide[rootBsize];
    // Dequantized-coeff element width (signed): the level clamps to
    // +-(1<<(7+bd)), a (bd+8)-bit value. 16 at bd 8 (byte-identical slots).
    final coefW = bitDepth + 8;
    final ctxN = sbMi;
    final cW = (sbMi + 1).bitLength;
    // tx16: enable inline TX_16X16 (256-coeff) leaf decode (maxTxN>=256).
    final tx16 = txLeaf && maxTxN >= 256;
    // tx32: enable inline TX_32X32 / TX_64X64 (1024-coeff) leaf decode
    // (maxTxN>=1024). Both use n=1024 (64x64 caps its coeffs to the 32x32
    // region), the leaf size enum (leafIs32 / leafIs64) selects tx_size cat +
    // dequant shift. Intra 32x32/64x64 use EXT_TX_SET_DCTONLY -> NO ext-tx
    // symbol is read (txType = DCT_DCT, TX_CLASS_2D), so the ext-tx state is
    // skipped for these leaves.
    final tx32 = txLeaf && maxTxN >= 1024;
    // chroma8: 4:2:0 chroma for a 16x16-root NONE leaf is an 8x8 block, ONE
    // TX_8X8 per plane (txsCtx 1) rather than the TX_4X4 an 8x8 luma leaf makes.
    // The chroma plane reuses the luma TX_8X8 geometry (levels8 / scan8 / cc8 /
    // deq8) and differs only in the plane-1 CDF banks + the 64-coeff output. A
    // build-time flag (rootBsize is a compile-time constant), so no runtime
    // 4x4-vs-8x8 chroma muxing is needed. chromaN sizes the U/V coeff RAMs.
    // With [chromaLeaf16] the SAME TX_8X8 chroma path is enabled for a bigger
    // root (32x32 / 64x64) whose leaves are all 16x16, so EVERY leaf's chroma is
    // an 8x8 block. The compile-time geometry is identical (levels8 / cc8 /
    // scan8 + plane-1 TX_8X8 banks), only the root/leaf count grows.
    // 4:4:4 per-leaf chroma: a 16x16 luma leaf's chroma is FULL resolution
    // (16x16), decoded as ONE TX_16X16 per plane (the chroma16 machinery) but
    // iterated per-leaf like chromaLeaf16. Selected by ssx==ssy==0.
    final chroma444Leaf = chroma && chromaLeaf16 && ssx == 0 && ssy == 0;
    // 4:2:2 per-leaf chroma: a 16x16 luma leaf's chroma is HALF-width, FULL-height
    // (8x16), decoded as ONE TX_8X16 (rect) per plane. Reuses the luma rect
    // TX_8X16 geometry (cc816 / _scan8x16 / levels8x16 / eob_pt-128) with plane-1
    // (txsCtx=2 + plane-1 eob-128) CDF banks. Selected by ssx==1 && ssy==0.
    final chroma422Leaf = chroma && chromaLeaf16 && ssx == 1 && ssy == 0;
    final chroma8 =
        chroma && (rootBsize == 6 || (chromaLeaf16 && ssx == 1 && ssy == 1));
    // chroma16: 4:2:0 chroma for a 32x32-root NONE leaf is a 16x16 block, ONE
    // TX_16X16 per plane (txsCtx 2). Reuses the luma TX_16X16 geometry (levels16
    // / scan16 / cc16 / deq16), same build-time pattern as chroma8.
    // chromaLeaf16 forces the TX_8X8 (chroma8) path even on a 32x32 root, so a
    // 32x32-root-with-16x16-leaves config is chroma8 not chroma16, EXCEPT the
    // 4:4:4 per-leaf case, whose full-res chroma IS a per-leaf TX_16X16.
    final chroma16 =
        chroma && ((rootBsize == 9 && !chromaLeaf16) || chroma444Leaf);
    final chromaN = chroma8
        ? 64
        : (chroma16 ? 256 : (chroma422Leaf ? 128 : 16));
    // shared scan-index width: 11 holds 0..1023 (TX_32X32/64X64), 9 holds
    // 0..255 (TX_16X16), 6 otherwise (legacy).
    final cidxW = tx32 ? 11 : (tx16 ? 9 : 6);
    // position-value width for the tx32 scan (1024 positions need 10 bits).
    const posW32 = 10;
    // ABOVE-context arrays span the tile width (Increment 2). `tileMiW == 0`
    // means "root width", so single-SB / pair configs keep `aboveCtxN == sbMi`
    // and `sb_c_mi` defaults to 0 -> byte-identical. LEFT arrays stay `ctxN`.
    final aboveCtxN = tileMiW == 0 ? sbMi : tileMiW;
    assert(aboveCtxN >= sbMi, 'tile width must cover at least one root SB');
    // absolute above-column index width: spans aboveCtxN + a root span for the
    // `+ bw4` write-range arithmetic headroom.
    final colW = (aboveCtxN + sbMi + 1).bitLength;
    const dStack = 96;
    final spW = (dStack + 1).bitLength;
    // qband-selected coeff CDF tables.
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
    // eob_pt-256 (TX_16X16 luma 2D + TX_16X16 chroma 2D) IS qctx-indexed, the
    // SW selects av1_default_eob_multi256_cdfs[qctx]. Previously hardcoded Q0.
    final eob256T = [
      cdf.kAv1EobBin256CdfQ0,
      cdf.kAv1EobBin256CdfQ1,
      cdf.kAv1EobBin256CdfQ2,
      cdf.kAv1EobBin256CdfQ3,
    ][qband];
    // eob_pt-128 (TX_16X8 / TX_8X16 rect leaves) IS qctx-indexed, the SW selects
    // av1_default_eob_multi128_cdfs[qctx]. Previously hardcoded Q0 (desynced at
    // qband != 0 because the rect eob_pt symbol was misdecoded).
    final eob128T = [
      cdf.kAv1EobBin128CdfQ0,
      cdf.kAv1EobBin128CdfQ1,
      cdf.kAv1EobBin128CdfQ2,
      cdf.kAv1EobBin128CdfQ3,
    ][qband];

    // Build-time preload schedule (52 contexts).
    final preloadCdfs = <List<int>>[];
    final preloadNsyms = <int>[];
    for (var k = 0; k < 16; k++) {
      preloadCdfs.add(cdf.kAv1DefaultPartitionCdf[(k >> 2) + 1][k & 3]);
      preloadNsyms.add((k >> 2) == 3 ? 4 : 10);
    }
    for (var i = 0; i < 3; i++) {
      preloadCdfs.add(cdf.kAv1DefaultSkipCdf[i]);
      preloadNsyms.add(2);
    }
    for (var i = 0; i < 25; i++) {
      preloadCdfs.add(cdf.kAv1DefaultKfYModeCdf[i]);
      preloadNsyms.add(13);
    }
    for (var i = 0; i < 8; i++) {
      preloadCdfs.add(_angleCdf[i]);
      preloadNsyms.add(7);
    }
    const cSkip0 = 16, cYmode0 = 19, cAngle0 = 44, cTxb = 52, cExtTx0 = 53;
    const cEobPt2d = 66, cEobPt1d = 67, cEobExtra0 = 68, cBypass = 77;
    const cBaseEob0 = 78, cBase0 = 82, cBr0 = 123; // 78..81, 82..122, 123..143
    const cDcSign0 = 144; // dc_sign 144..146
    // txLeaf 8x8 (txsCtx=1) coeff bank + tx_size depth CDF, appended at 147.
    const cTxSz0 = 147; // tx_size cat0 depth ctx 147..149
    const cTxb8 = 150; // txb_skip-8 ctx 150..162 (txbSkipCtx 0..12)
    const cExtTx8_0 = 163; // ext-tx-8 by y_mode 163..175
    const cEobPt8_2d = 176, cEobPt8_1d = 177; // eob_pt-64 2D / 1D
    const cEobExtra8_0 = 178; // eob_extra-8 bit ctx 178..186
    const cBaseEob8_0 = 187; // coeff_base_eob-8 187..190
    const cBase8_0 = 191; // coeff_base-8 191..231
    const cBr8_0 = 232; // coeff_br-8 232..252
    // chroma (planeType 1, TX_4X4 txsCtx 0) banks, appended at 253 with chroma.
    const cUvMode0 = 253; // uv_mode (cflAllowed, 14-sym) by y_mode 253..265
    const cCflSign = 266; // cfl_sign (8-sym) 266
    const cCflAlpha = 267; // cfl_alpha (16-sym) data-dependent reload 267
    const cTxbC0 = 268; // chroma txb_skip ctx 7..9 -> 268..270
    const cExtraC0 = 271; // chroma eob_extra 9 ctx 271..279
    const cEobPtC2d = 280; // chroma eob_pt-16 2D 280
    const cBaseEobC0 = 281; // chroma coeff_base_eob 4 ctx 281..284
    const cBaseC0 = 285; // chroma coeff_base 41 ctx 285..325
    const cBrC0 = 326; // chroma coeff_br 21 ctx 326..346
    const cDcSignC0 = 347; // chroma dc_sign 3 ctx 347..349
    if (coeffPrefix) {
      preloadCdfs.add(skipT[0]); // txb_skip ctx 52
      preloadNsyms.add(2);
      for (var i = 0; i < 13; i++) {
        preloadCdfs.add(_extTxByMode[i]); // ext-tx by y_mode ctx 53..65
        preloadNsyms.add(7);
      }
      preloadCdfs.add(eob16T[0]); // eob_pt 2D ctx 66
      preloadNsyms.add(5);
      preloadCdfs.add(eob16T[1]); // eob_pt 1D ctx 67
      preloadNsyms.add(5);
      for (var i = 0; i < 9; i++) {
        preloadCdfs.add(eobHiT[i]); // eob_extra bit ctx 68..76
        preloadNsyms.add(2);
      }
      preloadCdfs.add(const [16384, 0]); // bypass ctx 77
      preloadNsyms.add(2);
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[c]); // coeff_base_eob 78..81
        preloadNsyms.add(3);
      }
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[c]); // coeff_base 82..122
        preloadNsyms.add(4);
      }
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[c]); // coeff_br 123..143
        preloadNsyms.add(4);
      }
      for (var c = 0; c < 3; c++) {
        preloadCdfs.add(dcSignT[c]); // dc_sign 144..146
        preloadNsyms.add(2);
      }
    }
    if (txLeaf) {
      // tx_size cat0 depth CDF (BLOCK_8X8): 3 ctx rows of 2 syms, ctx 147..149.
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(cdf.kAv1DefaultTxSizeCdf[0][i]);
        preloadNsyms.add(2);
      }
      // TX_8X8 (txsCtx=1) luma coeff bank.
      for (var c = 0; c < 13; c++) {
        preloadCdfs.add(skipT[13 + c]); // txb_skip-8 ctx 150..162
        preloadNsyms.add(2);
      }
      for (var i = 0; i < 13; i++) {
        preloadCdfs.add(_extTxByMode8[i]); // ext-tx-8 by y_mode 163..175
        preloadNsyms.add(7);
      }
      preloadCdfs.add(eob64T[0]); // eob_pt-64 2D ctx 176
      preloadNsyms.add(7);
      preloadCdfs.add(eob64T[1]); // eob_pt-64 1D ctx 177
      preloadNsyms.add(7);
      for (var i = 0; i < 9; i++) {
        preloadCdfs.add(eobHiT[18 + i]); // eob_extra-8 bit ctx 178..186
        preloadNsyms.add(2);
      }
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[8 + c]); // coeff_base_eob-8 187..190
        preloadNsyms.add(3);
      }
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[82 + c]); // coeff_base-8 191..231
        preloadNsyms.add(4);
      }
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[42 + c]); // coeff_br-8 232..252 (txszGrp=1)
        preloadNsyms.add(4);
      }
    }
    if (chroma) {
      // uv_mode (cflAllowed, 14-sym) by y_mode 0..12 -> ctx 253..265.
      for (var i = 0; i < 13; i++) {
        preloadCdfs.add(cdf.kAv1DefaultUvModeCdfCflAllowed[i]);
        preloadNsyms.add(14);
      }
      preloadCdfs.add(_cflSignCdf); // cfl_sign ctx 266
      preloadNsyms.add(8);
      preloadCdfs.add(
        _cflAlphaCdf[0],
      ); // cfl_alpha ctx 267 (reloaded per decode)
      preloadNsyms.add(16);
      // chroma txb_skip ctx 7..9 (txsCtx 0 block) -> 268..270.
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(skipT[7 + i]);
        preloadNsyms.add(2);
      }
      // chroma eob_extra (txsCtx 0, planeType 1: +9) ctx 271..279.
      for (var i = 0; i < 9; i++) {
        preloadCdfs.add(eobHiT[9 + i]);
        preloadNsyms.add(2);
      }
      preloadCdfs.add(eob16T[2]); // chroma eob_pt-16 2D ctx 280
      preloadNsyms.add(5);
      // chroma coeff_base_eob (txsCtx 0, +4) ctx 281..284.
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[4 + c]);
        preloadNsyms.add(3);
      }
      // chroma coeff_base (txsCtx 0, +41) ctx 285..325.
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[41 + c]);
        preloadNsyms.add(4);
      }
      // chroma coeff_br (txszGrp 0, +21) ctx 326..346.
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[21 + c]);
        preloadNsyms.add(4);
      }
      // chroma dc_sign (+3) ctx 347..349.
      for (var c = 0; c < 3; c++) {
        preloadCdfs.add(dcSignT[3 + c]);
        preloadNsyms.add(2);
      }
    }
    // tx-split (depth 1) extra luma txb_skip contexts: the depth-1 sub-blocks
    // have planeBsize (8x8) != tx (4x4), so the txb_skip ctx is neighbour-derived
    // (skipCtx 1..6), unlike the existing 4x4-leaf / 8x8-leaf paths which only
    // ever use ctx 0 (cTxb). skipCtx 0 reuses cTxb, skipCtx 1..6 map here.
    // Appended LAST so the existing ctx numbers (incl. chroma) are untouched.
    final cTxbSplit0 = preloadCdfs.length; // skipCtx 1 -> here, ... skipCtx 6
    if (txLeaf) {
      for (var i = 1; i <= 6; i++) {
        preloadCdfs.add(skipT[i]); // skipQ[txsCtx=0 * 13 + i]
        preloadNsyms.add(2);
      }
    }
    // RECT (TX_8X4 / TX_4X8, n=32) geometry: it reuses the txsCtx=1 coeff banks
    // already preloaded by the txLeaf 8x8 block (cTxb8 / cBaseEob8_0 / cBase8_0 /
    // cBr8_0 / cEobExtra8_0 / cDcSign0) and the 4x4 ext-tx-by-mode bank cExtTx0
    // (squareTx=0 for rect). The ONLY new contexts are the eob_pt-32 2D / 1D
    // CDFs (6-sym). Appended after the split bank so all existing ctx numbers
    // stay byte-identical. Active ONLY on a HORZ/VERT rect leaf (never decoded
    // before this change), so a non-rect config is byte-identical.
    final cEobPt32_2d = preloadCdfs.length;
    if (txLeaf) {
      preloadCdfs.add(cdf.kAv1EobBin32CdfQ0[0]); // eob_pt-32 2D (luma)
      preloadNsyms.add(6);
      preloadCdfs.add(cdf.kAv1EobBin32CdfQ0[1]); // eob_pt-32 1D (luma)
      preloadNsyms.add(6);
    }
    final cEobPt32_1d = cEobPt32_2d + 1;
    // RECT-B (TX_16X8 / TX_8X16, n=128) geometry: reuses the txsCtx=2 coeff banks
    // (cBase16_0 / cBr16_0 / cBaseEob16_0 / cEobExtra16_0 / cTxb16) and the TX_8X8
    // ext-tx-by-mode bank cExtTx8_0 (squareTx=TX_8X8 for these rects, set 3, the
    // SAME eset/squareTx as the 8x8 leaf). The ONLY new contexts are the
    // eob_pt-128 2D / 1D CDFs (8-sym, qband-selected via eob128T). Gated on tx16
    // (the txsCtx=2 banks only exist then), a non-tx16 config never sees eb 4/5
    // so it is byte-identical. Appended here so all later ctx numbers still
    // self-index.
    final cEobPt128_2d = preloadCdfs.length;
    if (tx16) {
      preloadCdfs.add(eob128T[0]); // eob_pt-128 2D (luma)
      preloadNsyms.add(8);
      preloadCdfs.add(eob128T[1]); // eob_pt-128 1D (luma)
      preloadNsyms.add(8);
    }
    final cEobPt128_1d = cEobPt128_2d + 1;
    // cfl_alpha PERSISTENT contexts 1..5 (ctx 0 stays at cCflAlpha = 267). The
    // cfl_alpha CDF must ADAPT across the tile (a multi-SB CFL leaf reuses the
    // previous SB's adapted alpha CDF), so each of the 6 alpha contexts gets its
    // own persistent bank instead of a per-decode reload. Appended LAST so every
    // existing ctx number (incl. chroma) is byte-identical, ctx 0 reuses bank
    // 267 (already preloaded with _cflAlphaCdf[0]). Only with chroma.
    final cCflAlphaExt = preloadCdfs.length; // ctx 1 -> here ... ctx 5
    if (chroma) {
      for (var i = 1; i < 6; i++) {
        preloadCdfs.add(_cflAlphaCdf[i]);
        preloadNsyms.add(16);
      }
    }
    // TX_16X16 (txsCtx=2) inline coeff banks: appended LAST, gated on tx16, so
    // every existing ctx number is byte-identical when tx16 is off. 16x16 NONE
    // leaf uses txb_skip ctx 0, ext-tx is the 5-sym DTT4_IDTX set (2D only), eob
    // is the 256-bin, base/br/eob_extra are the txsCtx=2 slices, dc_sign reuses
    // cDcSign0 (plane-indexed, size-independent). The 256-bin eob_pt IS
    // qctx-indexed (eob256T[qband]), so tx16 works at every qband.
    final cTxb16 = preloadCdfs.length;
    final cExtTx16 = cTxb16 + 1;
    final cEobPt16 = cExtTx16 + 13;
    final cEobExtra16_0 = cEobPt16 + 1;
    final cBaseEob16_0 = cEobExtra16_0 + 9;
    final cBase16_0 = cBaseEob16_0 + 4;
    final cBr16_0 = cBase16_0 + 41;
    final cTxSz16_0 = cBr16_0 + 21; // tx_size cat1 (16x16) depth ctx, 3-sym
    // TX_32X32 / TX_64X64 (txsCtx=3 / 4) inline coeff banks: appended after the
    // tx16 banks, gated on tx32 (=> tx16), so every existing ctx number is
    // byte-identical when tx32 is off. Intra 32x32/64x64 use EXT_TX_SET_DCTONLY:
    // NO ext-tx symbol (txType=DCT_DCT, 2D), so there is no ext-tx bank. 32x32
    // and 64x64 share the 1024-bin eob_pt and the br group-3 bank, they differ
    // in txb_skip / eob_extra / base_eob / base (txsCtx 3 vs 4), the tx_size cat
    // (2 vs 3) and dequant shift (1 vs 2). 1024-bin is Q0-only => tx32 => qband0.
    final cTxb32 = cTxSz16_0 + 3;
    final cEobPt32 = cTxb32 + 1; // 1024-bin eob_pt, 11-sym (shared 32/64)
    final cEobExtra32_0 = cEobPt32 + 1;
    final cBaseEob32_0 = cEobExtra32_0 + 9;
    final cBase32_0 = cBaseEob32_0 + 4;
    final cBr32_0 = cBase32_0 + 41; // br group-3 bank (shared 32/64)
    final cTxSz32_0 = cBr32_0 + 21; // tx_size cat2 (32x32), 3-sym
    final cTxb64 = cTxSz32_0 + 3;
    final cEobExtra64_0 = cTxb64 + 1;
    final cBaseEob64_0 = cEobExtra64_0 + 9;
    final cBase64_0 = cBaseEob64_0 + 4;
    final cTxSz64_0 = cBase64_0 + 41; // tx_size cat3 (64x64), 3-sym
    if (tx16) {
      preloadCdfs.add(skipT[2 * 13]);
      preloadNsyms.add(2); // cTxb16 (skipCtx 0)
      for (var i = 0; i < 13; i++) {
        preloadCdfs.add(_extTxByMode16[i]);
        preloadNsyms.add(5);
      } // cExtTx16
      preloadCdfs.add(eob256T[0]);
      preloadNsyms.add(9); // cEobPt16 (2D)
      for (var c = 0; c < 9; c++) {
        preloadCdfs.add(eobHiT[2 * 18 + c]);
        preloadNsyms.add(2);
      } // cEobExtra16
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[2 * 8 + c]);
        preloadNsyms.add(3);
      } // cBaseEob16
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[2 * 82 + c]);
        preloadNsyms.add(4);
      } // cBase16
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[2 * 42 + c]);
        preloadNsyms.add(4);
      } // cBr16
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(cdf.kAv1DefaultTxSizeCdf[1][i]);
        preloadNsyms.add(3);
      } // cTxSz16_0 (cat1, 3-sym)
    }
    if (tx32) {
      // 32x32 (txsCtx=3).
      preloadCdfs.add(skipT[3 * 13]);
      preloadNsyms.add(2); // cTxb32 (skipCtx 0)
      preloadCdfs.add(cdf.kAv1EobBin1024CdfQ0[0]);
      preloadNsyms.add(11); // cEobPt32 (2D, 1024-bin, shared 32/64)
      for (var c = 0; c < 9; c++) {
        preloadCdfs.add(eobHiT[3 * 18 + c]);
        preloadNsyms.add(2);
      } // cEobExtra32
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[3 * 8 + c]);
        preloadNsyms.add(3);
      } // cBaseEob32
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[3 * 82 + c]);
        preloadNsyms.add(4);
      } // cBase32
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[3 * 42 + c]);
        preloadNsyms.add(4);
      } // cBr32 (group 3, shared 32/64)
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(cdf.kAv1DefaultTxSizeCdf[2][i]);
        preloadNsyms.add(3);
      } // cTxSz32_0 (cat2, 3-sym)
      // 64x64 (txsCtx=4).
      preloadCdfs.add(skipT[4 * 13]);
      preloadNsyms.add(2); // cTxb64
      for (var c = 0; c < 9; c++) {
        preloadCdfs.add(eobHiT[4 * 18 + c]);
        preloadNsyms.add(2);
      } // cEobExtra64
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[4 * 8 + c]);
        preloadNsyms.add(3);
      } // cBaseEob64
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[4 * 82 + c]);
        preloadNsyms.add(4);
      } // cBase64
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(cdf.kAv1DefaultTxSizeCdf[3][i]);
        preloadNsyms.add(3);
      } // cTxSz64_0 (cat3, 3-sym)
    }
    // Chroma TX_8X8 (planeType 1, txsCtx 1) coeff banks for a 16x16-root NONE
    // leaf's 4:2:0 chroma (8x8 per plane, ONE TX_8X8). Each plane-1 bank shifts
    // by one txsCtx stride vs the TX_4X4 chroma banks, dc_sign is size-
    // independent (reuses cDcSignC0). eob_pt is the 64-bin plane-1 2D CDF.
    // Appended LAST so every existing ctx number stays byte-identical when
    // chroma8 is off.
    final cTxbC8_0 = preloadCdfs.length; // chroma txb_skip-8 ctx 7..9
    final cEobPtC8_2d = cTxbC8_0 + 3; // chroma eob_pt-64 2D
    final cEobExtraC8_0 = cEobPtC8_2d + 1; // 9 ctx
    final cBaseEobC8_0 = cEobExtraC8_0 + 9; // 4 ctx
    final cBaseC8_0 = cBaseEobC8_0 + 4; // 41 ctx
    final cBrC8_0 = cBaseC8_0 + 41; // 21 ctx
    if (chroma8) {
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(skipT[1 * 13 + 7 + i]);
        preloadNsyms.add(2);
      }
      preloadCdfs.add(eob64T[2]); // chroma eob_pt-64 2D (plane 1)
      preloadNsyms.add(7);
      for (var i = 0; i < 9; i++) {
        preloadCdfs.add(eobHiT[1 * 18 + 9 + i]);
        preloadNsyms.add(2);
      }
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[1 * 8 + 4 + c]);
        preloadNsyms.add(3);
      }
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[1 * 82 + 41 + c]);
        preloadNsyms.add(4);
      }
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[1 * 42 + 21 + c]);
        preloadNsyms.add(4);
      }
    }
    // Chroma TX_16X16 (planeType 1, txsCtx 2) coeff banks for a 32x32-root NONE
    // leaf's 4:2:0 chroma (16x16 per plane, ONE TX_16X16). eob_pt is the 256-bin
    // plane-1 2D CDF (eob256T[2], qctx-indexed). dc_sign reuses cDcSignC0.
    final cTxbC16_0 = preloadCdfs.length; // chroma txb_skip-16 ctx 7..9
    final cEobPtC16_2d = cTxbC16_0 + 3;
    final cEobExtraC16_0 = cEobPtC16_2d + 1; // 9 ctx
    final cBaseEobC16_0 = cEobExtraC16_0 + 9; // 4 ctx
    final cBaseC16_0 = cBaseEobC16_0 + 4; // 41 ctx
    final cBrC16_0 = cBaseC16_0 + 41; // 21 ctx
    // The txsCtx=2 plane-1 banks are shared by 4:2:0 TX_16X16 chroma (chroma16)
    // AND 4:2:2 TX_8X16 chroma (chroma422Leaf) (both are planeType 1, txsCtx 2),
    // so preload them for either. The eob_pt differs (256-bin vs 128-bin) and is a
    // separate bank below.
    if (chroma16 || chroma422Leaf) {
      for (var i = 0; i < 3; i++) {
        preloadCdfs.add(skipT[2 * 13 + 7 + i]);
        preloadNsyms.add(2);
      }
      preloadCdfs.add(
        eob256T[2],
      ); // chroma eob_pt-256 2D (plane1, chroma16 only)
      preloadNsyms.add(9);
      for (var i = 0; i < 9; i++) {
        preloadCdfs.add(eobHiT[2 * 18 + 9 + i]);
        preloadNsyms.add(2);
      }
      for (var c = 0; c < 4; c++) {
        preloadCdfs.add(baseTokT[2 * 8 + 4 + c]);
        preloadNsyms.add(3);
      }
      for (var c = 0; c < 41; c++) {
        preloadCdfs.add(baseT[2 * 82 + 41 + c]);
        preloadNsyms.add(4);
      }
      for (var c = 0; c < 21; c++) {
        preloadCdfs.add(brT[2 * 42 + 21 + c]);
        preloadNsyms.add(4);
      }
    }
    // 4:2:2 chroma eob_pt-128 2D (planeType 1) bank (eob128T[2], qctx-indexed).
    final cEobPtC422_2d = preloadCdfs.length;
    if (chroma422Leaf) {
      preloadCdfs.add(eob128T[2]);
      preloadNsyms.add(8);
    }
    // filter_intra: 22 per-block-size use_filter_intra CDFs (2-sym) + the single
    // 5-sym filter_intra_mode CDF. Appended LAST (gated on enableFilterIntra) so
    // every existing ctx number is byte-identical when filter_intra is off.
    final cFilterIntra0 = preloadCdfs.length; // use_filter_intra ctx (by bsize)
    final cFilterIntraMode = cFilterIntra0 + 22;
    if (enableFilterIntra) {
      for (var i = 0; i < 22; i++) {
        preloadCdfs.add(_filterIntraCdf[i]);
        preloadNsyms.add(2);
      }
      preloadCdfs.add(_filterIntraModeCdf);
      preloadNsyms.add(5);
    }
    // PALETTE CDF banks (appended LAST, gated on enablePalette so every existing
    // ctx number is byte-identical when palette is off). Forward AOM_CDFn args
    // -> ICDF via _pi. Layout: y_size[7] (7-sym) | uv_size[7] (7-sym) |
    // y_mode[7*3] (2-sym) | uv_mode[2] (2-sym) | y_color[7*5] (nsyms=size) |
    // uv_color[7*5]. The color-index CDF for palette size `s` (2..8) at ctx `c`
    // is bank + (s-2)*5 + c with nsyms = s.
    List<int> pi(List<int> fwd) => [for (final x in fwd) 32768 - x, 0];
    final cPalYSize0 = preloadCdfs.length;
    final cPalUVSize0 = cPalYSize0 + 7;
    final cPalYMode0 = cPalUVSize0 + 7;
    final cPalUVMode0 = cPalYMode0 + 21;
    final cPalYColor0 = cPalUVMode0 + 2;
    final cPalUVColor0 = cPalYColor0 + 35;
    if (enablePalette) {
      for (var i = 0; i < 7; i++) {
        preloadCdfs.add(pi(_palYSizeFwd[i]));
        preloadNsyms.add(7);
      }
      for (var i = 0; i < 7; i++) {
        preloadCdfs.add(pi(_palUVSizeFwd[i]));
        preloadNsyms.add(7);
      }
      for (var b = 0; b < 7; b++) {
        for (var m = 0; m < 3; m++) {
          preloadCdfs.add(pi([_palYModeFwd[b][m]]));
          preloadNsyms.add(2);
        }
      }
      for (var m = 0; m < 2; m++) {
        preloadCdfs.add(pi([_palUVModeFwd[m]]));
        preloadNsyms.add(2);
      }
      for (var s = 0; s < 7; s++) {
        for (var c = 0; c < 5; c++) {
          preloadCdfs.add(pi(_palYColorFwd[s][c]));
          preloadNsyms.add(s + 2);
        }
      }
      for (var s = 0; s < 7; s++) {
        for (var c = 0; c < 5; c++) {
          preloadCdfs.add(pi(_palUVColorFwd[s][c]));
          preloadNsyms.add(s + 2);
        }
      }
    }
    final numCtx = preloadCdfs.length;

    createPort('clk', PortDirection.input);
    createPort('reset', PortDirection.input);
    createPort('start', PortDirection.input);
    createPort('bytes', PortDirection.input, width: maxBytes * 8);
    // Multi-superblock continuation (Increment 1). When `cont` is asserted on a
    // `start`, the walk CONTINUES the SAME od_ec window and the SAME adapted
    // CDF banks: it skips both the CDF preload (sPreload) AND the window init
    // (sInit), does NOT reload `bytes` and does NOT reset `cursor`, and
    // PRESERVES the above-* / above-EC / above-txfm context arrays so the new
    // superblock sees the previous SB-row's bottom edge. The left-* arrays are
    // CLEARED (a fresh superblock column starts with no left neighbours inside
    // the SB). `above_open` marks that the new SB has a decoded superblock row
    // ABOVE it (sb_r > 0): it forces the SB's TOP-edge availability so the top
    // leaves read the preserved above-* arrays (tile-relative availability,
    // mirroring Increment 0 in the recon walk). Both default 0, so a plain
    // single-SB `start` (cont = 0) is byte-identical to before. The ports only
    // EXIST when `multiSb` is set, otherwise the continuation logic sees
    // constant 0 (an unconnected input would otherwise float X into the FSM).
    // HORIZONTAL continuation (Increment 1b). `cont_left`, when asserted with
    // `cont`, PRESERVES the left-* arrays (left ctx / skip / ymode / EC / txfm)
    // instead of clearing them at the SB column start: the next SB sits to the
    // RIGHT of the previous one in the SAME superblock row, where AV1 keeps the
    // left context across superblocks (it is cleared only once per SB row, at
    // the tile-left). `left_open` is the symmetric counterpart to `above_open`:
    // it forces the SB's LEFT-edge availability (nc == 0 leaves see the
    // preserved left-* arrays = the previous SB's right edge). Both default 0,
    // so the existing vertical `cont`/`above_open` path is unchanged.
    if (multiSb) {
      createPort('cont', PortDirection.input);
      createPort('above_open', PortDirection.input);
      createPort('cont_left', PortDirection.input);
      createPort('left_open', PortDirection.input);
      // Tile-relative MI column of this SB (Increment 2): the absolute above-ctx
      // index is `sb_c_mi` + the leaf's local column. Only created when the
      // above arrays are actually tile-wide (`tileMiW` set), the existing
      // pair/single-SB wrappers (tileMiW == 0) do NOT connect it, so it must not
      // exist there (an unconnected input would float X into the column latch).
      if (tileMiW != 0) {
        createPort('sb_c_mi', PortDirection.input, width: colW);
      }
    }
    final contIn = multiSb ? input('cont') : Const(0);
    final aboveOpenIn = multiSb ? input('above_open') : Const(0);
    final contLeftIn = multiSb ? input('cont_left') : Const(0);
    final leftOpenIn = multiSb ? input('left_open') : Const(0);
    // Latched SB tile-column offset (Increment 2). Stable for the whole SB walk
    // (captured at the kicking `start`, like aboveOpenReg). 0 when not multiSb.
    final sbColMi = Logic(name: 'sb_col_mi', width: colW);
    if (coeffPrefix) {
      createPort('dc_q', PortDirection.input, width: 16);
      createPort('ac_q', PortDirection.input, width: 16);
    }
    addOutput('done');
    addOutput('leaf_count', width: 12);
    addOutput('sym_count', width: 12);
    addOutput('chk', width: 32);
    addOutput('above_ctx', width: ctxN * 5);
    addOutput('left_ctx', width: ctxN * 5);
    addOutput('above_skip', width: ctxN);
    addOutput('above_ymode', width: ctxN * 4);
    // Per-leaf decoded data (up to 4 leaves for an 8x8 SB), in DFS = raster
    // order, to feed the recon grid (coeffPrefix only).
    // Per-leaf coeff slot width: 16 coeffs (4x4) normally, 64 (8x8) with txLeaf.
    final leafCoeffN = txLeaf ? maxTxN : 16;
    if (coeffPrefix) {
      addOutput('leaf_ymodes', width: maxLeafOut * 4);
      // per-leaf RAW angle_delta_y (0..6, SW delta = raw-3). 0 (== delta 0)
      // for non-directional / sub-8x8 leaves. Consumed by the directional recon
      // predictor (delta = raw - 3, fed to HarborIntraDirEdge).
      addOutput('leaf_angles', width: maxLeafOut * 3);
      // per-leaf filter_intra: `leaf_use_filter_intra` is 1 bit per leaf (1 =
      // the leaf uses the FILTER_INTRA recursive predictor instead of DC), and
      // `leaf_filter_intra_modes` is the 0..4 filter_intra_mode (3 bits/leaf).
      // Both 0 when filter_intra is off / the leaf is ineligible. Only meaningful
      // (and only ever non-zero) when enableFilterIntra is set.
      if (enableFilterIntra) {
        addOutput('leaf_use_filter_intra', width: maxLeafOut);
        addOutput('leaf_filter_intra_modes', width: maxLeafOut * 3);
      }
      // per-leaf PALETTE decode outputs (enablePalette). leaf_has_pal_y = 1 when
      // the leaf uses a luma palette, leaf_pal_y_size = the 2..8 palette size (0
      // when unused), leaf_pal_y_colors = the 8 sorted base colors (8 bits each,
      // color k at [k*8 +: 8], zero above the size), leaf_pal_y_mapchk = a 32-bit
      // rolling hash (h = h*31 + idx) of the decoded color-index map in raster
      // order (proves the whole index map without a huge bus). UV mirrors Y (only
      // with chroma). All 0 when palette is off / the leaf has no palette.
      if (enablePalette) {
        addOutput('leaf_has_pal_y', width: maxLeafOut);
        addOutput('leaf_pal_y_size', width: maxLeafOut * 4);
        addOutput('leaf_pal_y_colors', width: maxLeafOut * 64);
        addOutput('leaf_pal_y_mapchk', width: maxLeafOut * 32);
        if (chroma) {
          addOutput('leaf_has_pal_uv', width: maxLeafOut);
          addOutput('leaf_pal_uv_size', width: maxLeafOut * 4);
          addOutput('leaf_pal_u_colors', width: maxLeafOut * 64);
          addOutput('leaf_pal_v_colors', width: maxLeafOut * 64);
          addOutput('leaf_pal_uv_mapchk', width: maxLeafOut * 32);
        }
      }
      addOutput('leaf_txtypes', width: maxLeafOut * 4);
      addOutput('leaf_coeffs', width: maxLeafOut * leafCoeffN * coefW);
      if (txLeaf) {
        addOutput('leaf_log2size', width: maxLeafOut * 3);
        // per-leaf rect kind for recon: 0 = NON-rect (square, use leaf_log2size)
        // otherwise 1 + rectKindReg encodes the rect geometry so recon knows
        // (bw,bh): 1=TX_8X4 2=TX_4X8 3=TX_16X8 4=TX_8X16 5=TX_16X4 6=TX_4X16.
        addOutput('leaf_rect_kinds', width: maxLeafOut * 3);
        // per-leaf tx_size depth (0 = TX_8X8 whole-block, 1 = four TX_4X4
        // sub-blocks). Lets recon map a depth-1 leaf to four 4x4 recon blocks.
        addOutput('leaf_tx_depth', width: maxLeafOut * 2);
        // depth-1 per-sub-block luma ext-tx types for the FIRST leaf only (the
        // whole 8x8 SB is one NONE leaf on this path). Sub-block s at [s*4 +: 4]
        // in raster order. Lets recon transform each 4x4 sub-block with its own
        // tx_type instead of replicating one. Don't-care on non-depth-1 leaves.
        addOutput('leaf_sub_txtypes', width: 4 * 4);
      }
    }
    if (chroma) {
      addOutput('leaf_uv_mode', width: 4);
      addOutput('leaf_cfl_alpha_idx', width: 8);
      addOutput('leaf_cfl_signs', width: 3);
      addOutput('leaf_u_coeffs', width: chromaN * coefW); // U raster (4x4/8x8)
      addOutput('leaf_v_coeffs', width: chromaN * coefW); // V raster (4x4/8x8)
      // per-leaf LUMA ext-tx type (preserved before the chroma decode clobbers
      // the shared txTypeReg). 4 leaves x 4 bits, same packing as leaf_txtypes.
      addOutput('leaf_luma_txtypes', width: maxLeafOut * 4);
      // MULTI-LEAF per-leaf chroma arrays (DFS order, indexed by leaf j). The
      // single leaf_* ports above still expose the LAST leaf (single-leaf
      // configs read leaf 0 there), these arrays carry every leaf's chroma so a
      // multi-leaf 64x64 SB can be reconstructed. Only emitted when chroma.
      addOutput('leaf_uv_modes', width: maxLeafOut * 4);
      // per-leaf RAW angle_delta_uv (0..6, SW delta = raw-3). 0 for
      // non-directional uv intra / sub-8x8 leaves.
      addOutput('leaf_uv_angles', width: maxLeafOut * 3);
      addOutput('leaf_cfl_alpha_idxs', width: maxLeafOut * 8);
      addOutput('leaf_cfl_signs_arr', width: maxLeafOut * 3);
      addOutput('leaf_u_coeffs_arr', width: maxLeafOut * chromaN * coefW);
      addOutput('leaf_v_coeffs_arr', width: maxLeafOut * chromaN * coefW);
    }

    final clk = input('clk');
    final reset = input('reset');

    final maxSyms = chroma ? 16 : 13;
    final ec = HarborOdEcDecoder(maxSyms: maxSyms, numCtx: numCtx, name: 'ec');
    addSubModule(ec);
    final cw = ec.ctxWidth;

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

    Logic selList(List<Logic> arr, Logic idx) {
      Logic v = arr.last;
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), arr[i], v);
      }
      return v;
    }

    // ceilLog2(range) for the palette colour-delta bit-width reduction. Mirrors
    // SW _ceilLog2: n < 2 (incl. a negative/underflowed range) -> 0, else the
    // bit-length of (n-1). `nr` is a 13-bit two's-complement value (bit 12 =
    // sign), range never exceeds 256 so (n-1) fits 9 bits.
    Logic palCeilLog2(Logic nr) {
      final neg = nr[12];
      final small = neg | nr.lt(Const(2, width: 13));
      final m = (nr - Const(1, width: 13)).getRange(0, 9); // n-1, 0..255
      Logic bl = Const(0, width: 5);
      for (var b = 1; b <= 9; b++) {
        bl = mux(m.gte(Const(1 << (b - 1), width: 9)), Const(b, width: 5), bl);
      }
      return mux(small, Const(0, width: 5), bl);
    }

    // cfl_alpha persistent bank for alpha context `row` (0..5): ctx 0 reuses
    // cCflAlpha (267), ctx 1..5 map to cCflAlphaExt + (row - 1).
    Logic cflAlphaBank(Logic row) => mux(
      row.eq(Const(0, width: 3)),
      Const(cCflAlpha, width: cw),
      (Const(cCflAlphaExt - 1, width: cw) + row.zeroExtend(cw)).getRange(0, cw),
    );

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

    Logic selPreloadCdf(Logic k) {
      Logic v = packCdf(preloadCdfs.last);
      for (var i = preloadCdfs.length - 2; i >= 0; i--) {
        v = mux(k.eq(Const(i, width: k.width)), packCdf(preloadCdfs[i]), v);
      }
      return v;
    }

    Logic selPreloadNsyms(Logic k) {
      Logic v = Const(preloadNsyms.last, width: 5);
      for (var i = preloadNsyms.length - 2; i >= 0; i--) {
        v = mux(
          k.eq(Const(i, width: k.width)),
          Const(preloadNsyms[i], width: 5),
          v,
        );
      }
      return v;
    }

    // arrays / stack / registers
    final aboveCtx = [
      for (var i = 0; i < aboveCtxN; i++) Logic(name: 'ac_$i', width: 5),
    ];
    final leftCtx = [
      for (var i = 0; i < ctxN; i++) Logic(name: 'lc_$i', width: 5),
    ];
    final aboveSkip = [
      for (var i = 0; i < aboveCtxN; i++) Logic(name: 'ask_$i'),
    ];
    final leftSkip = [for (var i = 0; i < ctxN; i++) Logic(name: 'lsk_$i')];
    final aboveYm = [
      for (var i = 0; i < aboveCtxN; i++) Logic(name: 'aym_$i', width: 4),
    ];
    final leftYm = [
      for (var i = 0; i < ctxN; i++) Logic(name: 'lym_$i', width: 4),
    ];
    // PALETTE neighbour arrays (enablePalette): per mi-column (above) / mi-row
    // (left) palette Y/UV sizes and the sorted base colours (Y[0..7] then U[0..7],
    // 16 x 8 bits packed, matching SW miPalColors). Updated at sUpd across the
    // block's covered mi range, read to build the colour cache (_getPaletteCache)
    // and the has_palette_y mode context (count of neighbours with palette).
    final abovePalY = enablePalette
        ? [for (var i = 0; i < aboveCtxN; i++) Logic(name: 'apy_$i', width: 4)]
        : <Logic>[];
    final abovePalUV = enablePalette
        ? [for (var i = 0; i < aboveCtxN; i++) Logic(name: 'apuv_$i', width: 4)]
        : <Logic>[];
    final abovePalCol = enablePalette
        ? [
            for (var i = 0; i < aboveCtxN; i++)
              Logic(name: 'apc_$i', width: 128),
          ]
        : <Logic>[];
    final leftPalY = enablePalette
        ? [for (var i = 0; i < ctxN; i++) Logic(name: 'lpy_$i', width: 4)]
        : <Logic>[];
    final leftPalUV = enablePalette
        ? [for (var i = 0; i < ctxN; i++) Logic(name: 'lpuv_$i', width: 4)]
        : <Logic>[];
    final leftPalCol = enablePalette
        ? [for (var i = 0; i < ctxN; i++) Logic(name: 'lpc_$i', width: 128)]
        : <Logic>[];
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
    final nr = Logic(name: 'nr', width: cW);
    final nc = Logic(name: 'nc', width: cW);
    final nbs = Logic(name: 'nbs', width: 5);
    final lr = [for (var i = 0; i < 4; i++) Logic(name: 'lr_$i', width: cW)];
    final lc = [for (var i = 0; i < 4; i++) Logic(name: 'lc_$i', width: cW)];
    final lbs = [for (var i = 0; i < 4; i++) Logic(name: 'lbs_$i', width: 5)];
    final leafN = Logic(name: 'leaf_n', width: 3);
    final emitIdx = Logic(name: 'emit_idx', width: 3);
    // preload index: must span numCtx (350 with chroma -> 9 bits), sized to the
    // od_ec ctx width so `pli.getRange(0, cw)` is always in range.
    final pliW = cw > 8 ? cw : 8;
    final pli = Logic(name: 'pli', width: pliW);
    final leafCount = Logic(name: 'leaf_count_r', width: 12);
    final symCount = Logic(name: 'sym_count_r', width: 12);
    final chk = Logic(name: 'chk_r', width: 32);
    // Increment 1: latched `above_open` for the current SB walk (set at the
    // `start` that kicks the SB, stable until the next start).
    final aboveOpenReg = Logic(name: 'above_open_r');
    // Increment 1b: latched `left_open` for the current SB walk (symmetric to
    // aboveOpenReg). Set at the `start` that kicks the SB, stable for the walk.
    final leftOpenReg = Logic(name: 'left_open_r');
    final skipReg = Logic(name: 'skip_r');
    final ymReg = Logic(name: 'ym_r', width: 4);
    final angReg = Logic(name: 'ang_r', width: 3); // raw decoded 0..6
    // raw decoded angle_delta_uv 0..6 (chroma only, 0 == delta 0 default).
    final angUvReg = Logic(name: 'ang_uv_r', width: 3);
    // filter_intra: use flag + mode (0..4), decoded after the chroma mode info.
    // Reset to 0 at each leaf's mode start, only written when the leaf is
    // filter-intra-eligible and use_filter_intra decodes to 1.
    final fiReg = enableFilterIntra ? Logic(name: 'fi_use_r') : null;
    final fiModeReg = enableFilterIntra
        ? Logic(name: 'fi_mode_r', width: 3)
        : null;
    // Effective intra direction for the luma ext-tx CDF context. libaom's
    // _readTxType uses fimode_to_intradir[filter_intra_mode] instead of the
    // (DC) y_mode when filter_intra is active, so the per-y_mode ext-tx bank
    // index must follow it or the luma coeff stream desyncs. Defaults to ymReg.
    final extTxDir = enableFilterIntra
        ? mux(fiReg!, romSel(_fimodeToIntradir, fiModeReg!, 4), ymReg)
        : ymReg;
    // PALETTE decode state (enablePalette). Colour depth fixed at 8-bit (all
    // in-scope streams are 8-bit 4:2:0/monochrome).
    const palBd = 8; // literal width for palette colours
    Logic? pReg(String n, [int w = 8]) =>
        enablePalette ? Logic(name: n, width: w) : null;
    List<Logic> pArr(String n, int cnt, [int w = 8]) => enablePalette
        ? [for (var i = 0; i < cnt; i++) Logic(name: '${n}_$i', width: w)]
        : <Logic>[];
    final palYSizeReg = pReg('pal_y_size', 4); // 0 = no luma palette
    final palUVSizeReg = pReg('pal_uv_size', 4); // 0 = no chroma palette
    final palColY = pArr('pcol_y', 8); // final sorted Y colours
    final palColU = pArr('pcol_u', 8);
    final palColV = pArr('pcol_v', 8);
    final palCached = pArr('pcache', 8); // cache-hit colours (sorted)
    final palNew = pArr('pnew', 8); // transmitted new colours (sorted)
    final palN = pReg('pal_n', 4); // current palette size being read
    final palIdx = pReg('pal_idx', 4); // colours placed so far / nCached
    final palPlane = pReg('pal_plane', 2); // 0=Y,1=U,2=V
    // cache merge pointers into the above/left neighbour colour lists.
    final palAi = pReg('pal_ai', 4);
    final palLi = pReg('pal_li', 4);
    final palAn = pReg('pal_an', 4);
    final palLn = pReg('pal_ln', 4);
    final palCacheVal = pReg('pal_cache_val', 8);
    final palLastCache = pReg('pal_last', 8);
    final palHaveLast = pReg('pal_have_last', 1);
    final palBits = pReg('pal_bits', 5); // current delta literal width
    final palRange = pReg('pal_range', 13);
    final palPrev = pReg('pal_prev', 9); // previous colour (for delta)
    final nNewReg = pReg('pal_nnew', 4);
    final pci = pReg('pal_ci', 4); // merge: cached index
    final pti = pReg('pal_ti', 4); // merge: new index
    final palMi = pReg('pal_mi', 4); // merge: output index
    // reusable literal-bit reader: reads palLitTarget bits (MSB-first) into
    // palLitAcc, then jumps to palLitRet.
    final palLitAcc = pReg('pal_lit', 16);
    final palLitCnt = pReg('pal_lit_cnt', 5);
    final palLitTarget = pReg('pal_lit_tgt', 5);
    final palLitRet = pReg('pal_lit_ret', 7);
    // colour-index-map tokens.
    final palMap = pArr('pal_map', 64, 4); // decoded map (raster), 4b idx
    final palTokPlane = pReg('pal_tok_plane', 1); // 0=Y,1=UV
    final palRows = pReg('pal_rows', 5);
    final palCols = pReg('pal_cols', 5);
    final palPlaneW = pReg('pal_pw', 5);
    final palTokI = pReg('pal_tok_i', 5); // wavefront diagonal
    final palTokJ = pReg('pal_tok_j', 5);
    final palMapChkY = pReg('pal_mapchk_y', 32);
    final palMapChkUV = pReg('pal_mapchk_uv', 32);
    // per-leaf palette emit buffers.
    final palHasYOut = enablePalette && coeffPrefix
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'phyo_$i')]
        : <Logic>[];
    final palYSizeOut = pArr(
      'pyso',
      enablePalette && coeffPrefix ? maxLeafOut : 0,
      4,
    );
    final palYColOut = pArr(
      'pyco',
      enablePalette && coeffPrefix ? maxLeafOut * 8 : 0,
      8,
    );
    final palYMapChkOut = pArr(
      'pymc',
      enablePalette && coeffPrefix ? maxLeafOut : 0,
      32,
    );
    final palHasUVOut = enablePalette && coeffPrefix && chroma
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'phuvo_$i')]
        : <Logic>[];
    final palUVSizeOut = pArr(
      'puvso',
      enablePalette && coeffPrefix && chroma ? maxLeafOut : 0,
      4,
    );
    final palUColOut = pArr(
      'puco',
      enablePalette && coeffPrefix && chroma ? maxLeafOut * 8 : 0,
      8,
    );
    final palVColOut = pArr(
      'pvco',
      enablePalette && coeffPrefix && chroma ? maxLeafOut * 8 : 0,
      8,
    );
    final palUVMapChkOut = pArr(
      'puvmc',
      enablePalette && coeffPrefix && chroma ? maxLeafOut : 0,
      32,
    );
    // palette color-index context submodule (wavefront neighbour scoring).
    final HarborPaletteColorContext? palCtxMod = enablePalette
        ? HarborPaletteColorContext(name: 'pal_ctx')
        : null;
    if (palCtxMod != null) addSubModule(palCtxMod);
    final allZeroReg = Logic(name: 'all_zero_r');
    final txTypeReg = Logic(name: 'txtype_r', width: 4);
    final classReg = Logic(
      name: 'class_r',
      width: 2,
    ); // 0 2D / 1 HORIZ / 2 VERT
    final eobPtReg = Logic(name: 'eob_pt_r', width: 4);
    final eobExtraReg = Logic(name: 'eob_extra_r', width: 11);
    final offBitsReg = Logic(name: 'off_bits_r', width: 4);
    final bypIdxReg = Logic(name: 'byp_idx_r', width: 4);
    final eobReg = Logic(name: 'eob_r', width: 11);
    final cIdx = Logic(name: 'c_idx', width: cidxW);
    final levelReg = Logic(name: 'level_r', width: 8);
    final brIdxReg = Logic(name: 'br_idx_r', width: 3);
    // padded levels buffer (TX_4X4: (4+4)*(4+4)+16 = 80), fed to coeff_context.
    const bufLen = 80;
    final levels = [
      for (var i = 0; i < bufLen; i++) Logic(name: 'lvl_$i', width: 8),
    ];
    // phase B: signs / golomb / dequant + neighbour EC arrays (8-bit:
    // culLevel[0:5] | dcSign[6:7]) for the dc_sign context.
    final aboveEC = [
      for (var i = 0; i < aboveCtxN; i++) Logic(name: 'aec_$i', width: 8),
    ];
    final leftEC = [
      for (var i = 0; i < ctxN; i++) Logic(name: 'lec_$i', width: 8),
    ];
    // CHROMA tile-width neighbour EC arrays (Stage 1, multiSb + chroma only).
    // 4:2:0 8x8-SB chroma is ONE 4x4 TXB per plane per SB column, so the chroma
    // EC granularity is one U slot + one V slot PER SB COLUMN (chroma slot index
    // = sbColMi >> 1). The above arrays span the chroma-slot count over the tile
    // width, the left arrays are a single chroma slot (the chroma analog of the
    // luma leftEC, cleared per SB column unless cont_left). All gated behind
    // (multiSb && chroma) so single-SB / non-multiSb configs are byte-identical
    // (those keep the hardcoded cTxbC0 / cDcSignC0 chroma ctx path).
    // The cross-SB SINGLE-4x4 chroma EC path is only for the single-8x8-leaf-per-
    // SB case (rootBsize 3, NOT chromaLeaf16). The multi-leaf TX_8X8 case
    // (chromaLeaf16) uses the intra-SB chroma8 arrays below, which are now
    // multiSb-capable (tile-wide above + cross-SB-preserved left), so those two
    // paths are mutually exclusive.
    final useChromaEC = multiSb && chroma && !chromaLeaf16;
    final aboveChromaN = useChromaEC
        ? ((aboveCtxN >> 1) < 1 ? 1 : (aboveCtxN >> 1))
        : 0;
    final aboveEcU = [
      for (var i = 0; i < aboveChromaN; i++) Logic(name: 'aecu_$i', width: 8),
    ];
    final aboveEcV = [
      for (var i = 0; i < aboveChromaN; i++) Logic(name: 'aecv_$i', width: 8),
    ];
    final leftEcU = useChromaEC ? Logic(name: 'lecu_r', width: 8) : null;
    final leftEcV = useChromaEC ? Logic(name: 'lecv_r', width: 8) : null;
    // INTRA-SB chroma EC arrays for the MULTI-LEAF TX_8X8 chroma (chromaLeaf16).
    // Each 8x8 chroma block's txb_skip / dc_sign context is neighbour-derived (SW
    // chroma _getTxbCtx: skipCtx = aboveEc + leftEc + 7, dc_sign from neighbour
    // sign nibbles) from its above/left chroma tx-block EC. Indexed by chroma 4x4
    // unit: above by column, left by row, each 8x8 block spans 2 units. U and V
    // use independent arrays.
    //
    // multiSb generalisation (mirrors the LUMA above/left model): the ABOVE array
    // is TILE-WIDE and indexed by ABSOLUTE chroma column (chromaColIdx + local),
    // so each SB column writes/reads its own band, it is cleared on a FRESH start
    // and PRESERVED on cont, so an SB below reads the SB-above's bottom chroma
    // edge (and the first SB row reads the zero-init untouched columns => no above
    // neighbour). The LEFT array is per-SB-row-height, indexed by local chroma
    // ROW, cleared per SB column UNLESS cont_left (a RIGHT-neighbour SB in the
    // same SB row preserves it => cross-SB left chroma neighbour). For the
    // non-multiSb single-SB path this collapses to the historic SB-wide local
    // index (byte-identical).
    final intraChromaEC = chroma && chromaLeaf16;
    // chroma 4x4-unit granularity = luma mi >> ss (2:1 at 4:2:0, 1:1 at 4:4:4,
    // 2:1 in X only at 4:2:2). chromaUnitsW/H = the chroma tx dim (16>>ss px) in
    // 4x4 units: 2 for TX_8X8, 4 for TX_16X16, (2 wide x 4 tall) for TX_8X16.
    final chromaUnitsW = (16 >> ssx) >> 2; // 2 (420/422) or 4 (444)
    final chromaUnitsH = (16 >> ssy) >> 2; // 2 (420) or 4 (444/422)
    final chromaEcLeftN = intraChromaEC ? (sbMi >> ssy) : 0;
    final chromaEcAboveN = intraChromaEC
        ? ((multiSb && tileMiW != 0) ? (tileMiW >> ssx) : (sbMi >> ssx))
        : 0;
    final aboveEcCU = [
      for (var i = 0; i < chromaEcAboveN; i++)
        Logic(name: 'caecu_$i', width: 8),
    ];
    final aboveEcCV = [
      for (var i = 0; i < chromaEcAboveN; i++)
        Logic(name: 'caecv_$i', width: 8),
    ];
    final leftEcCU = [
      for (var i = 0; i < chromaEcLeftN; i++) Logic(name: 'clecu_$i', width: 8),
    ];
    final leftEcCV = [
      for (var i = 0; i < chromaEcLeftN; i++) Logic(name: 'clecv_$i', width: 8),
    ];
    // The LUMA neighbour EC (aboveEC/leftEC) must be the leaf's LUMA block EC,
    // but culLevelReg/dcSignReg are SHARED with the chroma U/V planes and hold
    // the V-plane value by the time sUpd writes the luma neighbour arrays. Latch
    // the luma EC when the luma plane (coeffPlane 0) finishes, and use it for the
    // sUpd luma-neighbour write so chroma coeffs no longer corrupt it.
    final lumaEcReg = chroma ? Logic(name: 'luma_ec_r', width: 8) : null;
    // chroma slot index for the current SB (= sbColMi >> 1). colW-wide enough.
    Logic chromaColIdx() => (sbColMi >> 1).getRange(0, colW);
    // select the chroma above-EC slot at the current SB's chroma column.
    Logic selChromaAbove(List<Logic> arr) {
      if (arr.isEmpty) return Const(0, width: 8);
      Logic v = arr.last;
      final idx = chromaColIdx();
      for (var i = arr.length - 2; i >= 0; i--) {
        v = mux(idx.eq(Const(i, width: idx.width)), arr[i], v);
      }
      return v;
    }

    // Absolute chroma above-EC column for a leaf's LOCAL chroma unit column `lc`
    // (= ec2>>1). Tile-wide (chromaColIdx + local) under multiSb so each SB
    // column addresses its own band of the tile-wide aboveEcC arrays, local
    // (byte-identical) otherwise.
    Logic chromaAboveIdx(Logic lc) => (multiSb && tileMiW != 0)
        ? (chromaColIdx() + lc.zeroExtend(colW)).getRange(0, colW)
        : lc.getRange(0, cW);
    final signReg = Logic(name: 'sign_r');
    final pbLevelReg = Logic(name: 'pb_level_r', width: 21);
    final golLeadReg = Logic(name: 'gol_lead_r', width: 6);
    final golXReg = Logic(name: 'gol_x_r', width: 21);
    final golCntReg = Logic(name: 'gol_cnt_r', width: 6);
    final culLevelReg = Logic(name: 'cul_level_r', width: 7);
    final dcSignReg = Logic(name: 'dc_sign_r', width: 2); // 0 none/1 neg/2 pos
    // coeff buffer: 16 coeffs (4x4) normally, 64 (8x8) with txLeaf. The 4x4
    // path fills [0..15], the txLeaf 8x8 path fills all 64.
    final coeffsRam = [
      for (var i = 0; i < leafCoeffN; i++) Logic(name: 'coef_$i', width: coefW),
    ];
    // per-leaf output buffers (up to 4 leaves).
    final ymodeOut = [
      for (var i = 0; i < maxLeafOut; i++) Logic(name: 'ymo_$i', width: 4),
    ];
    // per-leaf RAW angle_delta_y (0..6). Snapshotted from angReg at leaf emit.
    final angleOut = [
      for (var i = 0; i < maxLeafOut; i++) Logic(name: 'ango_$i', width: 3),
    ];
    // per-leaf filter_intra use flag + mode (0..4). Snapshotted from fiReg /
    // fiModeReg at leaf emit, only allocated when enableFilterIntra.
    final fiUseOut = enableFilterIntra
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'fio_$i')]
        : <Logic>[];
    final fiModeOut = enableFilterIntra
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'fimo_$i', width: 3),
          ]
        : <Logic>[];
    final txtypeOut = [
      for (var i = 0; i < maxLeafOut; i++) Logic(name: 'txo_$i', width: 4),
    ];
    final coeffsOut = [
      for (var i = 0; i < maxLeafOut * leafCoeffN; i++)
        Logic(name: 'cfo_$i', width: coefW),
    ];
    // txLeaf state: per-leaf log2 size out (3 = 8x8, 2 = 4x4), the decoded leaf
    // tx (0=TX_4X4 split [future] / 1=TX_8X8), an 8x8 levels buffer (padded:
    // (8+4)*(8+4)+16 = 160), and the above/left txfm-size context arrays (pixel
    // width/height of each mi column/row's tx, for `_txSizeContext`).
    const bufLen8 = 160;
    final log2Out = txLeaf
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'l2o_$i', width: 3)]
        : <Logic>[];
    final rectKindOut = txLeaf
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'rko_$i', width: 3)]
        : <Logic>[];
    final txDepthOut = txLeaf
        ? [for (var i = 0; i < maxLeafOut; i++) Logic(name: 'tdo_$i', width: 2)]
        : <Logic>[];
    final leafTx = Logic(name: 'leaf_tx_r'); // 1 = TX_8X8
    // 1 = TX_16X16 NONE leaf (tx16 only). Set at sTxSzCap when eb==BLOCK_16X16
    // and the tx_size depth is 0.
    final leafTx16Reg = tx16 ? Logic(name: 'leaf_tx16_r') : null;
    // 16x16 luma tx_size depth-1 split: a BLOCK_16X16 leaf whose tx_size decodes
    // to depth 1 is FOUR TX_8X8 transform blocks (raster order, reusing the leafTx
    // TX_8X8 coeff machinery). split16Active marks the sweep is running, subBlk
    // counts the four TX_8X8 sub-blocks, leaf16SplitReg persists to the leaf emit
    // (txDepthOut=1, suppresses the batched luma-EC write which the per-sub-block
    // EC writes already handle). The TX_8X8 sub-block txb_skip/dc_sign ctx is
    // neighbour-derived from the real luma aboveEC/leftEC (2-unit spans) since the
    // plane block (16x16) != the tx (8x8). Depth-2 (sixteen TX_4X4) is out of
    // scope for these DCT-only streams (never observed).
    final split16Active = tx16 ? Logic(name: 'split16_active_r') : null;
    final leaf16SplitReg = tx16 ? Logic(name: 'leaf16_split_r') : null;
    // 1 = a TX_32X32 or TX_64X64 NONE leaf (tx32 only). Set at sTxSzCap when
    // eb==BLOCK_32X32/64X64 and the tx_size depth is 0. leafIs64 distinguishes
    // 64x64 (for txsCtx=4 banks + dequant shift 2 + tx_size cat3).
    final leafTx32Reg = tx32 ? Logic(name: 'leaf_tx32_r') : null;
    // RECT geometry state (txLeaf only): leafRect marks the active leaf uses the
    // n=32 rect tx (TX_8X4 / TX_4X8), rectVert selects TX_4X8 (1, bhl=3) vs
    // TX_8X4 (0, bhl=2). When leafRect is set, leafTx is 0 so EVERY existing
    // mux(leafTx,...) site keeps picking the 4x4 path, a separate outer
    // mux(leafRect, rect..., <existing>) overrides only on a rect leaf. leafRect
    // can only be set under a HORZ/VERT 8x8 partition (eb 1/2), which the FSM
    // never coeff-decoded before, so a non-rect run is byte-identical.
    final leafRect = txLeaf ? Logic(name: 'leaf_rect_r') : null;
    final rectVert = txLeaf ? Logic(name: 'rect_vert_r') : null;
    // Extended rect geometry (larger rects): rectKindReg identifies the active
    // rect tx among all six shapes so the shared rect coeff datapath can pick the
    // right cc / scan / CDF bank / eob_pt / raster.  0=TX_8X4, 1=TX_4X8 (both
    // n=32, txsCtx=1, eob_pt-32), 2=TX_16X8, 3=TX_8X16 (n=128, txsCtx=2,
    // eob_pt-128, ext-tx cExtTx8_0), 4=TX_16X4, 5=TX_4X16 (n=64, txsCtx=1,
    // eob_pt-64 reusing cEobPt8, ext-tx cExtTx0). Set alongside leafRect/rectVert
    // at leaf setup. Only kinds 2..5 need tx16 (the txsCtx=2 banks), a non-tx16
    // run never sets them, so it stays byte-identical.
    final rectKindReg = txLeaf ? Logic(name: 'rect_kind_r', width: 3) : null;
    // tx-split (depth 1) state: txDepthReg holds the decoded depth (0 = one
    // TX_8X8 block, 1 = four TX_4X4 sub-blocks), splitActive marks the depth-1
    // path is running, subBlk counts the four sub-blocks (raster: 0=(0,0),
    // 1=(0,4), 2=(4,0), 3=(4,4)). subAboveEC/subLeftEC are the WITHIN-LEAF
    // neighbour-EC arrays at 4x4-tx granularity over the 8x8 leaf (2 entries),
    // updated between sub-blocks so the txb_skip/dc_sign ctx propagates exactly
    // like libaom's _getTxbCtx/_setEntropyCtx.
    final txDepthReg = txLeaf ? Logic(name: 'tx_depth_r', width: 2) : null;
    final splitActive = txLeaf ? Logic(name: 'split_active_r') : null;
    final subBlk = txLeaf ? Logic(name: 'sub_blk_r', width: 2) : null;
    // Per-sub-block luma ext-tx type for a depth-1 8x8 leaf, raster order
    // (s 0..3 = sub-block (0,0),(0,1),(1,0),(1,1)). The shared txTypeReg holds
    // only the LAST sub-block's tx_type, but recon needs each sub-block's own
    // tx_type for its 4x4 inverse transform. Snapshot at each sExtTxCap into
    // subTxType[subBlk], an all-zero sub-block leaves its entry 0 (matching
    // txTypeReg's all_zero reset). Exposed via leaf_sub_txtypes. Non-depth-1
    // paths leave it at reset 0 (don't-care).
    final subTxType = txLeaf
        ? [for (var i = 0; i < 4; i++) Logic(name: 'subtx_$i', width: 4)]
        : <Logic>[];
    final subAboveEC = txLeaf
        ? [for (var i = 0; i < 2; i++) Logic(name: 'saec_$i', width: 8)]
        : <Logic>[];
    final subLeftEC = txLeaf
        ? [for (var i = 0; i < 2; i++) Logic(name: 'slec_$i', width: 8)]
        : <Logic>[];
    // chroma state: uv_mode / cfl idx+signs, the coeff-plane selector (0 luma /
    // 1 U / 2 V) gating the chroma CDF banks, and the U/V coeff output buffers.
    final uvModeReg = Logic(name: 'uv_mode_r', width: 4);
    final cflIdxReg = Logic(name: 'cfl_idx_r', width: 8);
    final cflSignsReg = Logic(name: 'cfl_signs_r', width: 3);
    // packed luma base symbols (8 x 4 bits) + base ctx idxs (8 x 6 bits).
    final coeffPlane = chroma ? Logic(name: 'coeff_plane_r', width: 2) : null;
    // On the chroma path the shared `txTypeReg` is clobbered to 0 by the chroma
    // plane decode (chroma is always TX_CLASS_2D / DCT) before the leaf emit, so
    // the LUMA ext-tx type would be lost in `leaf_txtypes`. Capture it into a
    // per-leaf luma-tx-type buffer at the luma ext-tx cap (coeffPlane 0) and
    // expose it via `leaf_luma_txtypes` so a downstream recon can transform the
    // luma block with the correct tx_type.
    final lumaTxOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'ltxo_$i', width: 4),
          ]
        : <Logic>[];
    final uCoeffsRam = chroma
        ? [
            for (var i = 0; i < chromaN; i++)
              Logic(name: 'ucoef_$i', width: coefW),
          ]
        : <Logic>[];
    final vCoeffsRam = chroma
        ? [
            for (var i = 0; i < chromaN; i++)
              Logic(name: 'vcoef_$i', width: coefW),
          ]
        : <Logic>[];
    // MULTI-LEAF per-leaf chroma output registers (indexed by leaf j in DFS
    // order). Filled at the sUpd leaf emit from the per-leaf uvModeReg /
    // cflIdxReg / cflSignsReg / uCoeffsRam / vCoeffsRam. Exposed via the
    // leaf_uv_modes / leaf_cfl_alpha_idxs / leaf_cfl_signs_arr /
    // leaf_u_coeffs_arr / leaf_v_coeffs_arr arrays.
    final uvModeOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'uvmo_$i', width: 4),
          ]
        : <Logic>[];
    // per-leaf RAW angle_delta_uv (0..6). Snapshotted from angUvReg at emit.
    final uvAngleOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'uvango_$i', width: 3),
          ]
        : <Logic>[];
    final cflIdxOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'cflio_$i', width: 8),
          ]
        : <Logic>[];
    final cflSignsOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut; i++)
              Logic(name: 'cflso_$i', width: 3),
          ]
        : <Logic>[];
    final uCoeffsOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut * chromaN; i++)
              Logic(name: 'ucoefo_$i', width: coefW),
          ]
        : <Logic>[];
    final vCoeffsOut = chroma
        ? [
            for (var i = 0; i < maxLeafOut * chromaN; i++)
              Logic(name: 'vcoefo_$i', width: coefW),
          ]
        : <Logic>[];
    // cfl combinational helpers (data-dependent alpha-row + sign branch), built
    // from the captured js (== cflSignsReg).
    final isChroma = coeffPlane != null
        ? coeffPlane.neq(Const(0, width: 2))
        : Const(0);
    final isPlaneV = coeffPlane != null
        ? coeffPlane.eq(Const(2, width: 2))
        : Const(0);
    final levels8 = txLeaf
        ? [for (var i = 0; i < bufLen8; i++) Logic(name: 'lvl8_$i', width: 8)]
        : <Logic>[];
    // TX_16X16 levels buffer (bufLen = (16+4)*(16+4)+16 = 416). tx16 only.
    const bufLen16 = 416;
    final levels16 = tx16
        ? [for (var i = 0; i < bufLen16; i++) Logic(name: 'lvl16_$i', width: 8)]
        : <Logic>[];
    // TX_32X32 / TX_64X64 levels buffer (bufLen = (32+4)*(32+4)+16 = 1312).
    // tx32 only (64x64 coeffs cap to the 32x32 region, so one 32x32 buffer
    // serves both). Matches HarborCoeffContext(txSize:3) levels width.
    const bufLen32 = (32 + 4) * (32 + 4) + 16;
    final levels32 = tx32
        ? [for (var i = 0; i < bufLen32; i++) Logic(name: 'lvl32_$i', width: 8)]
        : <Logic>[];
    // RECT levels buffers (txLeaf only). HarborCoeffContext bufLen for both
    // TX_8X4 (bhl=2,w=8) and TX_4X8 (bhl=3,w=4) is (h+4)*(w+4)+16 = 112, but the
    // internal stride differs (8 vs 12), so each rect kind gets its own buffer,
    // written only when its kind is the active leaf. The inactive one stays 0.
    const bufLenRect = 112;
    final levels8x4 = txLeaf
        ? [for (var i = 0; i < bufLenRect; i++) Logic(name: 'l84_$i', width: 8)]
        : <Logic>[];
    final levels4x8 = txLeaf
        ? [for (var i = 0; i < bufLenRect; i++) Logic(name: 'l48_$i', width: 8)]
        : <Logic>[];
    // Larger-rect levels buffers. TX_16X8 (w16,h8) / TX_8X16 (w8,h16):
    // (h+4)*(w+4)+16 = 256 each, gated on tx16 (their txsCtx=2 banks). TX_16X4
    // (w16,h4) / TX_4X16 (w4,h16): 176 each, gated on txLeaf (txsCtx=1 banks, can
    // occur from a 1:4 split of a 16x16 root even without a 16x16-leaf path).
    const bufLenRectB = 256, bufLenRectC = 176;
    final levels16x8 = tx16
        ? [
            for (var i = 0; i < bufLenRectB; i++)
              Logic(name: 'l168_$i', width: 8),
          ]
        : <Logic>[];
    final levels8x16 = tx16
        ? [
            for (var i = 0; i < bufLenRectB; i++)
              Logic(name: 'l816_$i', width: 8),
          ]
        : <Logic>[];
    final levels16x4 = txLeaf
        ? [
            for (var i = 0; i < bufLenRectC; i++)
              Logic(name: 'l164_$i', width: 8),
          ]
        : <Logic>[];
    final levels4x16 = txLeaf
        ? [
            for (var i = 0; i < bufLenRectC; i++)
              Logic(name: 'l416_$i', width: 8),
          ]
        : <Logic>[];
    final aboveTxfm = txLeaf
        ? [for (var i = 0; i < aboveCtxN; i++) Logic(name: 'atx_$i', width: 7)]
        : <Logic>[];
    final leftTxfm = txLeaf
        ? [for (var i = 0; i < ctxN; i++) Logic(name: 'ltx_$i', width: 7)]
        : <Logic>[];

    // node-derived (read-node) values
    final level = (romSel(_miWideLog2, nbs, 4) - Const(1, width: 4)).getRange(
      0,
      4,
    );
    final psubLevelBase = (level.zeroExtend(8) * Const(10, width: 8)).getRange(
      0,
      8,
    );
    Logic subOf(int part) => romSel(
      _psub,
      (psubLevelBase + Const(part, width: 8)).getRange(0, 8),
      5,
    );
    final sub = [for (var p = 0; p < 10; p++) subOf(p)];
    final half = (romSel(_miWide, nbs, 6) >> 1).getRange(0, cW);
    final quarter = (romSel(_miWide, nbs, 6) >> 2).getRange(0, cW);
    // Tile-relative TOP-edge availability (Increment 1): a leaf on the SB top
    // edge (nr == 0) is "above-available" when `above_open` (the SB has a
    // decoded superblock row above it). The preserved above-* arrays then hold
    // the previous SB's bottom edge. `above_open` is held in a register
    // (aboveOpenReg) so it is stable for the whole SB walk.
    final availU =
        nr.gt(Const(0, width: cW)) |
        (nr.eq(Const(0, width: cW)) & aboveOpenReg);
    // Symmetric LEFT-edge availability (Increment 1b): a leaf on the SB left
    // edge (nc == 0) is "left-available" when `left_open` (an SB decoded to its
    // left in the same SB row). The preserved left-* arrays then hold that SB's
    // right edge.
    final availL =
        nc.gt(Const(0, width: cW)) | (nc.eq(Const(0, width: cW)) & leftOpenReg);
    // ABSOLUTE above-column index (Increment 2): the tile-width above-* arrays
    // are indexed by `sb_c_mi` + the local column. With a root-width tile
    // (aboveCtxN == sbMi) sbColMi is 0 so this collapses to the local column and
    // every selList chain is unchanged. The index is colW-wide to span the tile.
    Logic aAbs(Logic localCol) =>
        (localCol.zeroExtend(colW) + sbColMi).getRange(0, colW);
    final aboveBit = availU & (selList(aboveCtx, aAbs(nc)) >> level)[0];
    final leftBit = availL & (selList(leftCtx, nr) >> level)[0];
    final nodeCtx = ((leftBit.zeroExtend(2) << 1) | aboveBit.zeroExtend(2))
        .getRange(0, 2);
    final partIdxCtxBase =
        ((Const(3, width: cw) - level.zeroExtend(cw)) * Const(4, width: cw))
            .getRange(0, cw);
    final readCtxIdx = (partIdxCtxBase + nodeCtx.zeroExtend(cw)).getRange(
      0,
      cw,
    );

    // current-leaf (emitIdx) derived values for mode-info.
    final er = selList(lr, emitIdx);
    final ec2 = selList(lc, emitIdx);
    final eb = selList(lbs, emitIdx);
    final lAvailU =
        er.gt(Const(0, width: cW)) |
        (er.eq(Const(0, width: cW)) & aboveOpenReg);
    final lAvailL =
        ec2.gt(Const(0, width: cW)) |
        (ec2.eq(Const(0, width: cW)) & leftOpenReg);
    final aSkipV = mux(lAvailU, selList(aboveSkip, aAbs(ec2)), Const(0));
    final lSkipV = mux(lAvailL, selList(leftSkip, er), Const(0));
    final skipCtxV = (aSkipV.zeroExtend(2) + lSkipV.zeroExtend(2)).getRange(
      0,
      2,
    );
    final aModeV = mux(
      lAvailU,
      selList(aboveYm, aAbs(ec2)),
      Const(0, width: 4),
    );
    final lModeV = mux(lAvailL, selList(leftYm, er), Const(0, width: 4));
    final ymCtxIdxV =
        (romSel(_intraModeContext, aModeV, 5).zeroExtend(5) *
                    Const(5, width: 5) +
                romSel(_intraModeContext, lModeV, 5).zeroExtend(5))
            .getRange(0, 5); // 0..24
    final skipDecCtx = (Const(cSkip0, width: cw) + skipCtxV.zeroExtend(cw))
        .getRange(0, cw);
    final ymDecCtx = (Const(cYmode0, width: cw) + ymCtxIdxV.zeroExtend(cw))
        .getRange(0, cw);
    final angDecCtx =
        (Const(cAngle0, width: cw) +
                (ymReg - Const(1, width: 4)).zeroExtend(cw))
            .getRange(0, cw);
    // angle is read when block >= 8x8 (eb >= 3) and mode is directional (1..8).
    final isDir = ymReg.gte(Const(1, width: 4)) & ymReg.lte(Const(8, width: 4));
    final useAngle = eb.gte(Const(3, width: 5)) & isDir;
    // 4:2:0 chromaRef for the current (emitIdx) leaf: the block owns the chroma
    // of its collocated luma region. Per libaom (ssx=ssy=1):
    //   chromaRef = ((r&1)!=0 || (bh4&1)==0) && ((c&1)!=0 || (bw4&1)==0).
    // For the NONE 8x8 leaf (eb=3, bw4=bh4=2 even) this is always true (so the
    // existing NONE chroma path is unchanged), for a SPLIT 4x4 leaf (eb=0,
    // bw4=bh4=1) it reduces to (r&1)!=0 && (c&1)!=0, true ONLY at the
    // bottom-right 4x4 (leaf 3). Gates whether this leaf decodes the chroma
    // mode info (uv_mode/cfl/angle_uv) and, after its luma coeffs, the U/V
    // chroma transform blocks.
    final ebBw4 = romSel(_miWide, eb, 8);
    final ebBh4 = romSel(_miHigh, eb, 8);
    final chromaRefV = chroma
        ? ((er[0] | ~ebBh4[0]) & (ec2[0] | ~ebBw4[0]))
        : Const(0);
    // eob derived values (coeffPrefix).
    final class2d = classReg.eq(Const(0, width: 2));
    final eobPtDecCtx = mux<Logic>(
      class2d,
      Const(cEobPt2d, width: cw),
      Const(cEobPt1d, width: cw),
    );
    final eobCtxIdx = (eobPtReg - Const(3, width: 4)).getRange(0, 4);
    final eobExtraDecCtx =
        (Const(cEobExtra0, width: cw) + eobCtxIdx.zeroExtend(cw)).getRange(
          0,
          cw,
        );
    final offBits = romSel(_eobOffsetBits, eobPtReg, 4);
    final groupStart = romSel(_eobGroupStart, eobPtReg, 11);

    // base/br reverse-scan combinational (coeffPrefix)
    int paddedIdx(int pos) => pos + ((pos >> 2) << 2); // TX_4X4 bhl=2
    final posOfCidx = mux(
      classReg.eq(Const(2, width: 2)),
      romSel(_mrow4, cIdx, 6),
      mux(
        classReg.eq(Const(1, width: 2)),
        romSel(_mcol4, cIdx, 6),
        romSel(_scan4, cIdx, 6),
      ),
    );
    final isEobMinus1 = cIdx.eq(
      (eobReg - Const(1, width: 11)).getRange(0, cidxW),
    );
    final isC0c = cIdx.eq(Const(0, width: cidxW));
    final cc = HarborCoeffContext(txSize: 0, name: 'cc');
    addSubModule(cc);
    cc.input('coeff_idx').srcConnection! <=
        posOfCidx.getRange(0, cc.input('coeff_idx').width);
    final ccScanW = cc.input('scan_idx').width;
    cc.input('scan_idx').srcConnection! <=
        (ccScanW <= cidxW
            ? cIdx.getRange(0, ccScanW)
            : cIdx.zeroExtend(ccScanW));
    cc.input('tx_class').srcConnection! <= classReg;
    cc.input('levels').srcConnection! <=
        [for (var i = bufLen - 1; i >= 0; i--) levels[i]].concat();
    final baseEobCtx = cc.output('base_eob_ctx');
    final base2dCtx = cc.output('base_ctx_2d');
    final baseGenCtx = cc.output('base_ctx_gen');
    final brEobCtx = cc.output('br_ctx_eob');
    final br2dCtx = cc.output('br_ctx_2d');
    final brGenCtx = cc.output('br_ctx_gen');
    final class2dc = classReg.eq(Const(0, width: 2));
    Logic baseEobFlat() =>
        (Const(cBaseEob0, width: cw) + baseEobCtx.zeroExtend(cw)).getRange(
          0,
          cw,
        );
    Logic baseFlatFor(Logic ctx) =>
        (Const(cBase0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
    final base2dPath = mux(
      isC0c,
      baseFlatFor(baseGenCtx),
      baseFlatFor(base2dCtx),
    );
    final nonEob1Base = mux(class2dc, base2dPath, baseFlatFor(baseGenCtx));
    final baseFlat = mux(isEobMinus1, baseEobFlat(), nonEob1Base);
    final baseNsyms = mux<Logic>(
      isEobMinus1,
      Const(3, width: 5),
      Const(4, width: 5),
    );
    final br2dPath = mux(
      isC0c,
      brGenCtx.zeroExtend(cw),
      br2dCtx.zeroExtend(cw),
    );
    final nonEob1Br = mux(class2dc, br2dPath, brGenCtx.zeroExtend(cw));
    final brSubCtx = mux(isEobMinus1, brEobCtx.zeroExtend(cw), nonEob1Br);
    final brFlat = (Const(cBr0, width: cw) + brSubCtx).getRange(0, cw);
    Logic cap8(Logic v) => v.getRange(0, 8);

    // phase B combinational
    final isC0pb = cIdx.eq(Const(0, width: cidxW)); // DC in the forward scan
    int paddedIdxOf(int pos) => pos + ((pos >> 2) << 2);
    int rasterOf(int pos) => (pos & 3) * 4 + (pos >> 2);
    // current level = levels[paddedIdx(posOfCidx)].
    Logic pbLevelCur = levels[paddedIdxOf(15)];
    for (var p = 14; p >= 0; p--) {
      pbLevelCur = mux(
        posOfCidx.eq(Const(p, width: 6)),
        levels[paddedIdxOf(p)],
        pbLevelCur,
      );
    }
    // Per-unit dc_sign contribution (3-bit signed): 1 neg -> -1, 2 pos -> +1.
    // Shared helper, the depth-1 tx-split path sums exactly one above + one left
    // 4x4 unit with it below.
    Logic ecContrib(Logic ecVal) {
      final bits = ecVal.getRange(6, 8); // 0 none / 1 neg / 2 pos
      return mux(
        bits.eq(Const(1, width: 2)),
        Const(7, width: 3), // -1
        mux<Logic>(
          bits.eq(Const(2, width: 2)),
          Const(1, width: 3),
          Const(0, width: 3),
        ),
      );
    }

    // Leaf-level luma dc_sign context: libaom's get_txb_ctx sums the sign
    // contribution of EVERY above unit across the tx width (txwU) and EVERY
    // left unit across the tx height (txhU), not just one each. Reading a
    // single unit is only correct when all neighbour units are identical
    // (all-square-same-size), which is why the all-16x16 path passed, a rect
    // partition splits the left/above span into differently-signed leaves
    // (e.g. a 16x16 leaf whose left column is a 16x8 over another 16x8), so
    // the single-unit read picks the wrong sign sum and mis-selects the
    // dc_sign CDF, desyncing the od_ec stream. Match SW _getTxbCtx exactly.
    // (The depth-1 tx-split path keeps its own single-unit aEcS/lEcS sum: a
    // 4x4 sub-block spans exactly one mi unit, so one each is correct there.)
    Logic ecContribS(Logic ecVal) {
      final bits = ecVal.getRange(6, 8); // 0 none / 1 neg / 2 pos
      return mux(
        bits.eq(Const(1, width: 2)),
        Const(0x1f, width: 5), // -1
        mux<Logic>(
          bits.eq(Const(2, width: 2)),
          Const(1, width: 5),
          Const(0, width: 5),
        ),
      );
    }

    Logic dcSignSum = Const(0, width: 5);
    for (var k = 0; k < 4; k++) {
      final incl = lAvailU & Const(k, width: 8).lt(ebBw4);
      final col = aAbs((ec2 + Const(k, width: cW)).getRange(0, cW));
      final v = mux(incl, selList(aboveEC, col), Const(0, width: 8));
      dcSignSum = (dcSignSum + ecContribS(v)).getRange(0, 5);
    }
    for (var k = 0; k < 4; k++) {
      final incl = lAvailL & Const(k, width: 8).lt(ebBh4);
      final row = (er + Const(k, width: cW)).getRange(0, cW);
      final v = mux(incl, selList(leftEC, row), Const(0, width: 8));
      dcSignSum = (dcSignSum + ecContribS(v)).getRange(0, 5);
    }
    final dcSignCtxV = mux(
      dcSignSum[4],
      Const(1, width: 2), // sum < 0 -> ctx 1
      mux<Logic>(
        dcSignSum.eq(Const(0, width: 5)),
        Const(0, width: 2),
        Const(2, width: 2),
      ),
    );
    final dcSignDecCtx =
        (Const(cDcSign0, width: cw) + dcSignCtxV.zeroExtend(cw)).getRange(
          0,
          cw,
        );

    // CHROMA neighbour-derived txb_skip / dc_sign ctx (Stage 1)
    // For 4:2:0 8x8 SBs the chroma 4x4 TXB has NO in-SB chroma neighbour, so its
    // above/left neighbours come ONLY from adjacent SBs: the above neighbour is
    // the previous SB-row's chroma EC (available when aboveOpenReg, held in the
    // tile-width aboveEcU/V at this SB's chroma column), the left neighbour is
    // the previous SB-column's chroma EC in the same SB row (available when
    // leftOpenReg, held in leftEcU/V). U and V use INDEPENDENT arrays. Selected
    // by the live plane (isPlaneV) so the U decode reads the U neighbours and the
    // V decode reads the V neighbours. Mirrors SW chroma _getTxbCtx (off = 7).
    Logic? chromaSkipCtx, chromaDcSignCtx;
    if (useChromaEC) {
      final aU = mux(
        aboveOpenReg,
        selChromaAbove(aboveEcU),
        Const(0, width: 8),
      );
      final aV = mux(
        aboveOpenReg,
        selChromaAbove(aboveEcV),
        Const(0, width: 8),
      );
      final lU = mux(leftOpenReg, leftEcU!, Const(0, width: 8));
      final lV = mux(leftOpenReg, leftEcV!, Const(0, width: 8));
      final cA = mux(isPlaneV, aV, aU);
      final cL = mux(isPlaneV, lV, lU);
      // txb_skip: aboveEc(bool from cul_level bits[0:5]) + leftEc + off(7).
      final aBool = cA.getRange(0, 6).neq(Const(0, width: 6));
      final lBool = cL.getRange(0, 6).neq(Const(0, width: 6));
      final cSkipV = (aBool.zeroExtend(2) + lBool.zeroExtend(2)).getRange(
        0,
        2,
      ); // 0..2
      chromaSkipCtx = (Const(cTxbC0, width: cw) + cSkipV.zeroExtend(cw))
          .getRange(0, cw);
      // dc_sign: sum of the >>6 sign contributions of the chroma neighbours.
      final cSum = (ecContrib(cA) + ecContrib(cL)).getRange(0, 3); // -2..2
      final cSignV = mux(
        cSum[2],
        Const(1, width: 2),
        mux<Logic>(
          cSum.eq(Const(0, width: 3)),
          Const(0, width: 2),
          Const(2, width: 2),
        ),
      );
      chromaDcSignCtx = (Const(cDcSignC0, width: cw) + cSignV.zeroExtend(cw))
          .getRange(0, cw);
    }

    // INTRA-SB neighbour-derived chroma txb_skip / dc_sign ctx
    // For the multi-leaf chromaLeaf16 path each chroma tx block reads its in-SB
    // above/left chroma neighbours (chromaUnitsW above units, chromaUnitsH left
    // units). skipCtx = aboveEc + leftEc + off (base cTxbC8_0 for TX_8X8 / 4:2:0,
    // cTxbC16_0 for the TX_16X16 4:4:4 chroma: off is 7 for a full-block tx in
    // every uniform-leaf case). dc_sign ctx from the neighbour sign counts. The
    // chroma unit column/row is `luma mi >> ss` (2:1 at 4:2:0, 1:1 at 4:4:4).
    Logic? chromaSkip8Ctx, chromaDcSign8Ctx;
    if (intraChromaEC) {
      final cSkipBase = (chroma16 || chroma422Leaf) ? cTxbC16_0 : cTxbC8_0;
      final lc0 = (ec2 >> ssx).getRange(0, cW);
      final lr0 = (er >> ssy).getRange(0, cW);
      Logic aSel(Logic i) =>
          mux(isPlaneV, selList(aboveEcCV, i), selList(aboveEcCU, i));
      Logic lSel(Logic i) =>
          mux(isPlaneV, selList(leftEcCV, i), selList(leftEcCU, i));
      // Gather the neighbour EC units the chroma tx spans in each dimension.
      final aUnits = <Logic>[
        for (var u = 0; u < chromaUnitsW; u++)
          aSel(chromaAboveIdx((lc0 + Const(u, width: cW)).getRange(0, cW))),
      ];
      final lUnits = <Logic>[
        for (var u = 0; u < chromaUnitsH; u++)
          lSel((lr0 + Const(u, width: cW)).getRange(0, cW)),
      ];
      // txb_skip: aboveEc = any nonzero cul_level (bits[0:5]) in the above units.
      // leftEc similarly. ctx = off + aboveEc + leftEc.
      final aBool = aUnits
          .map((v) => v.getRange(0, 6).neq(Const(0, width: 6)))
          .reduce((a, b) => a | b);
      final lBool = lUnits
          .map((v) => v.getRange(0, 6).neq(Const(0, width: 6)))
          .reduce((a, b) => a | b);
      final cSkip = (aBool.zeroExtend(2) + lBool.zeroExtend(2)).getRange(
        0,
        2,
      ); // 0..2
      chromaSkip8Ctx = (Const(cSkipBase, width: cw) + cSkip.zeroExtend(cw))
          .getRange(0, cw);
      // dc_sign: pos/neg counts over the spanned neighbour units (bits[6:8]:
      // 1 neg, 2 pos). ctx = pos>neg ? 2 : (pos==neg ? 0 : 1).
      Logic isPos(Logic v) => v.getRange(6, 8).eq(Const(2, width: 2));
      Logic isNeg(Logic v) => v.getRange(6, 8).eq(Const(1, width: 2));
      final all = [...aUnits, ...lUnits];
      final cntW = (all.length + 1).bitLength;
      final posN = all
          .map((v) => isPos(v).zeroExtend(cntW))
          .reduce((a, b) => (a + b).getRange(0, cntW));
      final negN = all
          .map((v) => isNeg(v).zeroExtend(cntW))
          .reduce((a, b) => (a + b).getRange(0, cntW));
      final cSign8 = mux(
        posN.gt(negN),
        Const(2, width: 2),
        mux<Logic>(posN.eq(negN), Const(0, width: 2), Const(1, width: 2)),
      );
      chromaDcSign8Ctx = (Const(cDcSignC0, width: cw) + cSign8.zeroExtend(cw))
          .getRange(0, cw);
    }

    // rect-leaf tx_size depth ctx (txLeaf)
    // A rect leaf is eb == BLOCK_4X8 (1, VERT) or BLOCK_8X4 (2, HORZ), both have
    // bsize_to_tx_size_cat == 0 (same tx_size CDF bank cTxSz0 as the 8x8 leaf)
    // but a NEIGHBOUR-derived _txSizeContext (not hardwired 0). maxW/maxH come
    // from the rect tx: TX_4X8 -> (4,8), TX_8X4 -> (8,4). above/left compare the
    // neighbour aboveTxfm[ec2]/leftTxfm[er] (pixel tx width/height) to maxW/maxH.
    Logic? rectTxSizeCtx;
    // Rect leaves span the six shapes whose largest rect tx has both dims <= 16:
    //   BLOCK_4X8(1) BLOCK_8X4(2) BLOCK_8X16(4) BLOCK_16X8(5) BLOCK_4X16(16)
    //   BLOCK_16X4(17).  The bigger four require tx16 (txsCtx=2 banks) for 4/5.
    //   The 4x16/16x4 pair only needs txLeaf. leafRectKind encodes the geometry.
    final leafIsRect = txLeaf
        ? (eb.eq(Const(1, width: 5)) |
              eb.eq(Const(2, width: 5)) |
              (tx16 ? eb.eq(Const(4, width: 5)) : Const(0)) |
              (tx16 ? eb.eq(Const(5, width: 5)) : Const(0)) |
              eb.eq(Const(16, width: 5)) |
              eb.eq(Const(17, width: 5)))
        : Const(0);
    final leafRectVert = txLeaf ? eb.eq(Const(1, width: 5)) : Const(0);
    // leafRectKind: 0=TX_8X4(eb2) 1=TX_4X8(eb1) 2=TX_16X8(eb5) 3=TX_8X16(eb4)
    // 4=TX_16X4(eb17) 5=TX_4X16(eb16). Default 0.
    final leafRectKind = txLeaf
        ? mux(
            eb.eq(Const(1, width: 5)),
            Const(1, width: 3),
            mux(
              eb.eq(Const(5, width: 5)),
              Const(2, width: 3),
              mux(
                eb.eq(Const(4, width: 5)),
                Const(3, width: 3),
                mux(
                  eb.eq(Const(17, width: 5)),
                  Const(4, width: 3),
                  mux<Logic>(
                    eb.eq(Const(16, width: 5)),
                    Const(5, width: 3),
                    Const(0, width: 3),
                  ),
                ),
              ),
            ),
          )
        : Const(0, width: 3);
    if (txLeaf) {
      // per-kind max rect tx width/height (leafRectKind 0..5).
      Logic isKc(int k) => leafRectKind.eq(Const(k, width: 3));
      // width: k0=8 k1=4 k2=16 k3=8 k4=16 k5=4
      final maxW = mux(
        isKc(2) | isKc(4),
        Const(16, width: 7),
        mux<Logic>(isKc(1) | isKc(5), Const(4, width: 7), Const(8, width: 7)),
      );
      // height: k0=4 k1=8 k2=8 k3=16 k4=4 k5=16
      final maxH = mux(
        isKc(3) | isKc(5),
        Const(16, width: 7),
        mux<Logic>(isKc(1) | isKc(2), Const(8, width: 7), Const(4, width: 7)),
      );
      final aTx = mux(lAvailU, selList(aboveTxfm, aAbs(ec2)), maxW);
      final lTx = mux(lAvailL, selList(leftTxfm, er), maxH);
      final above = aTx.gte(maxW); // 1-bit
      final left = lTx.gte(maxH);
      rectTxSizeCtx = mux(
        lAvailU & lAvailL,
        (above.zeroExtend(2) + left.zeroExtend(2)).getRange(0, 2),
        mux(
          lAvailU,
          above.zeroExtend(2),
          mux(lAvailL, left.zeroExtend(2), Const(0, width: 2)),
        ),
      );
    }
    // rect tx_size CDF category: kinds 2..5 (16x8/8x16/16x4/4x16) are cat 1
    // (3-sym, cTxSz16_0 bank, needs tx16), kinds 0/1 (8x4/4x8) are cat 0
    // (2-sym, cTxSz0 bank).
    final leafRectCat1 = txLeaf
        ? leafRectKind.gte(Const(2, width: 3))
        : Const(0);
    // 16x16-leaf tx_size depth ctx (tx16)
    // BLOCK_16X16 leaf: cat 1, 3-sym, ctx = (aboveTx>=16)+(leftTx>=16) from the
    // neighbour txfm-size arrays (maxW=maxH=16), mirroring the rect path.
    final leafIs16 = tx16 ? eb.eq(Const(6, width: 5)) : Const(0);
    Logic? tx16Ctx;
    if (tx16) {
      final aTx16 = mux(
        lAvailU,
        selList(aboveTxfm, aAbs(ec2)),
        Const(16, width: 7),
      );
      final lTx16 = mux(lAvailL, selList(leftTxfm, er), Const(16, width: 7));
      final a16 = aTx16.gte(Const(16, width: 7));
      final l16 = lTx16.gte(Const(16, width: 7));
      tx16Ctx = mux(
        lAvailU & lAvailL,
        (a16.zeroExtend(2) + l16.zeroExtend(2)).getRange(0, 2),
        mux(
          lAvailU,
          a16.zeroExtend(2),
          mux(lAvailL, l16.zeroExtend(2), Const(0, width: 2)),
        ),
      );
    }
    // 32x32 / 64x64-leaf tx_size depth ctx (tx32)
    // get_tx_size_context: above = aboveTxfm[c] >= maxW, left = leftTxfm[r] >=
    // maxH, with maxW=maxH = 32 (BLOCK_32X32) or 64 (BLOCK_64X64). The threshold
    // is muxed by leafIs64.
    final leafIs32 = tx32 ? eb.eq(Const(9, width: 5)) : Const(0);
    final leafIs64 = tx32 ? eb.eq(Const(12, width: 5)) : Const(0);
    Logic? tx32Ctx;
    if (tx32) {
      final thr = mux<Logic>(
        leafIs64,
        Const(64, width: 7),
        Const(32, width: 7),
      );
      final aTx = mux(
        lAvailU,
        selList(aboveTxfm, aAbs(ec2)),
        Const(64, width: 7),
      );
      final lTx = mux(lAvailL, selList(leftTxfm, er), Const(64, width: 7));
      final aB = aTx.gte(thr);
      final lB = lTx.gte(thr);
      tx32Ctx = mux(
        lAvailU & lAvailL,
        (aB.zeroExtend(2) + lB.zeroExtend(2)).getRange(0, 2),
        mux(
          lAvailU,
          aB.zeroExtend(2),
          mux(lAvailL, lB.zeroExtend(2), Const(0, width: 2)),
        ),
      );
    }

    // tx-split (depth 1) sub-block context combinational
    // subBlk -> 4x4-tx position in the 8x8 leaf: colOff = subBlk[0],
    // rowOff = subBlk[1] (raster order). The within-leaf neighbour EC for this
    // sub-block is subAboveEC[colOff] (above) and subLeftEC[rowOff] (left), both
    // 0 before the first sub-block touches them, then propagated by earlier
    // sub-blocks. txwU == txhU == 1 (a single 4x4 unit), so the libaom OR/sum is
    // over one above + one left entry.
    Logic? splitTxbSkipCtx, splitDcSignCtx, splitColOff, splitRowOff;
    if (txLeaf) {
      final col = subBlk![0]; // 0 or 1
      final row = subBlk[1];
      splitColOff = col;
      splitRowOff = row;
      final aEcS = mux(col, subAboveEC[1], subAboveEC[0]);
      final lEcS = mux(row, subLeftEC[1], subLeftEC[0]);
      // txb_skip ctx: top = aEc & 63, left = lEc & 63, each clamped to 4, then
      // _txbSkipCtx[top*5 + left]. ctx 52 + skipCtx (the 4x4 txb_skip bank).
      Logic clamp4(Logic v) {
        final m = v.getRange(0, 6); // & 63
        return mux(
          m.gt(Const(4, width: 6)),
          Const(4, width: 3),
          m.getRange(0, 3),
        );
      }

      final topC = clamp4(aEcS);
      final leftC = clamp4(lEcS);
      final skTblIdx =
          ((topC.zeroExtend(5) * Const(5, width: 5)).getRange(0, 5) +
                  leftC.zeroExtend(5))
              .getRange(0, 5);
      final skipCtx = romSel(_txbSkipCtx, skTblIdx, 3); // 0..6
      // skipCtx 0 -> cTxb (skipQ[0]), skipCtx 1..6 -> the appended split bank.
      splitTxbSkipCtx = mux(
        skipCtx.eq(Const(0, width: 3)),
        Const(cTxb, width: cw),
        (Const(cTxbSplit0, width: cw) +
                (skipCtx - Const(1, width: 3)).zeroExtend(cw))
            .getRange(0, cw),
      );
      // dc_sign ctx: ecContrib(aEc) + ecContrib(lEc) summed (signed -2..2) ->
      // _dcSignContexts via the same dcSignCtxV mapping, base ctx cDcSign0.
      final dcSumS = (ecContrib(aEcS) + ecContrib(lEcS)).getRange(0, 3);
      final dcCtxS = mux(
        dcSumS[2],
        Const(1, width: 2),
        mux<Logic>(
          dcSumS.eq(Const(0, width: 3)),
          Const(0, width: 2),
          Const(2, width: 2),
        ),
      );
      splitDcSignCtx = (Const(cDcSign0, width: cw) + dcCtxS.zeroExtend(cw))
          .getRange(0, cw);
    }

    // 16x16 depth-1 (four TX_8X8) sub-block context combinational
    // The current TX_8X8 sub-block sits at (aCol,lRow) = (ec2 + colOff*2, er +
    // rowOff*2) in 4x4-unit coords (colOff/rowOff = subBlk[0]/[1]). It reads the
    // REAL luma aboveEC/leftEC arrays (two units in each dimension) so external
    // neighbours (from adjacent leaves) AND within-leaf propagation (each finished
    // sub-block writes its cul back into those arrays) are handled exactly like
    // libaom _getTxbCtx. txb_skip: plane_bsize(16x16) != tx(8x8) -> the 5x5
    // skip_contexts table over top=OR(a0,a1), left=OR(l0,l1), ctx bank cTxb8 +
    // skipCtx (the txsCtx=1 skip bank, ctx 0..6). dc_sign: signed sum over the two
    // above + two left units, mapped 0/1/2 (bank cDcSign0, size-independent).
    Logic? split16SkipCtx, split16DcSignCtx;
    if (tx16 && txLeaf) {
      final col = subBlk![0];
      final row = subBlk[1];
      final aCol0 = (ec2 + (col.zeroExtend(cW) << 1)).getRange(0, cW);
      final aCol1 = (aCol0 + Const(1, width: cW)).getRange(0, cW);
      final lRow0 = (er + (row.zeroExtend(cW) << 1)).getRange(0, cW);
      final lRow1 = (lRow0 + Const(1, width: cW)).getRange(0, cW);
      final a0 = selList(aboveEC, aAbs(aCol0));
      final a1 = selList(aboveEC, aAbs(aCol1));
      final l0 = selList(leftEC, lRow0);
      final l1 = selList(leftEC, lRow1);
      Logic clamp4(Logic v) {
        final m = v.getRange(0, 6); // & 63
        return mux(
          m.gt(Const(4, width: 6)),
          Const(4, width: 3),
          m.getRange(0, 3),
        );
      }

      final topC = clamp4((a0 | a1).getRange(0, 8));
      final leftC = clamp4((l0 | l1).getRange(0, 8));
      final skTblIdx =
          ((topC.zeroExtend(5) * Const(5, width: 5)).getRange(0, 5) +
                  leftC.zeroExtend(5))
              .getRange(0, 5);
      final skipCtx16 = romSel(_txbSkipCtx, skTblIdx, 3); // 0..6
      split16SkipCtx = (Const(cTxb8, width: cw) + skipCtx16.zeroExtend(cw))
          .getRange(0, cw);
      final dcSum16 =
          (ecContribS(a0) + ecContribS(a1) + ecContribS(l0) + ecContribS(l1))
              .getRange(0, 5);
      final dcCtx16 = mux(
        dcSum16[4],
        Const(1, width: 2),
        mux<Logic>(
          dcSum16.eq(Const(0, width: 5)),
          Const(0, width: 2),
          Const(2, width: 2),
        ),
      );
      split16DcSignCtx = (Const(cDcSign0, width: cw) + dcCtx16.zeroExtend(cw))
          .getRange(0, cw);
    }

    Logic? dqCoeff;
    if (coeffPrefix) {
      final deq = HarborDequant(bitDepth: bitDepth, name: 'deq');
      addSubModule(deq);
      deq.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deq.input('dc_q').srcConnection! <= input('dc_q');
      deq.input('ac_q').srcConnection! <= input('ac_q');
      deq.input('is_dc').srcConnection! <= isC0pb;
      deq.input('sign').srcConnection! <= signReg;
      deq.input('shift').srcConnection! <= Const(0, width: 2);
      dqCoeff = deq.output('dq_coeff');
    }

    // chroma combinational: uv_mode CDF row, cfl sign/alpha, chroma coeff CDF
    // banks (planeType 1, TX_4X4 txsCtx 0).
    Logic? cflAlphaRowU,
        cflAlphaRowV,
        cflSignVnz,
        baseCFlat,
        brCFlat,
        eobExtraCDecCtx,
        dcSignCDecCtx;
    if (chroma) {
      // cfl: from the captured js (cflSignsReg): signU = (js+1)/3,
      // signV = (js+1)-3*signU, alpha rows rowU = js+1-3, rowV = signV*3+signU-3.
      final jsP1 = (cflSignsReg.zeroExtend(5) + Const(1, width: 5)).getRange(
        0,
        5,
      );
      Logic divBy3(Logic v) => mux(
        v.gte(Const(6, width: 5)),
        Const(2, width: 5),
        mux<Logic>(
          v.gte(Const(3, width: 5)),
          Const(1, width: 5),
          Const(0, width: 5),
        ),
      ).getRange(0, 5);
      final signU = divBy3(jsP1);
      final signV = (jsP1 - (signU * Const(3, width: 5)).getRange(0, 5))
          .getRange(0, 5);
      cflAlphaRowU = (jsP1 - Const(3, width: 5)).getRange(0, 3);
      cflAlphaRowV =
          ((signV * Const(3, width: 5)).getRange(0, 5) +
                  signU.zeroExtend(5) -
                  Const(3, width: 5))
              .getRange(0, 3);
      cflSignVnz = signV.neq(Const(0, width: 5));
      // chroma base/br flat (the `cc` 4x4 context module fed by `levels`, with
      // the chroma CDF bases). Mirrors the luma 4x4 base/br muxing.
      Logic baseEobFlatC() =>
          (Const(cBaseEobC0, width: cw) + baseEobCtx.zeroExtend(cw)).getRange(
            0,
            cw,
          );
      Logic baseFlatForC(Logic ctx) =>
          (Const(cBaseC0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
      final base2dPathC = mux(
        isC0c,
        baseFlatForC(baseGenCtx),
        baseFlatForC(base2dCtx),
      );
      // chroma is always TX_CLASS_2D, so the non-eob path is the 2D path.
      final nonEob1BaseC = base2dPathC;
      baseCFlat = mux(isEobMinus1, baseEobFlatC(), nonEob1BaseC);
      final br2dPathC = mux(
        isC0c,
        brGenCtx.zeroExtend(cw),
        br2dCtx.zeroExtend(cw),
      );
      final brSubCtxC = mux(isEobMinus1, brEobCtx.zeroExtend(cw), br2dPathC);
      brCFlat = (Const(cBrC0, width: cw) + brSubCtxC).getRange(0, cw);
      eobExtraCDecCtx = (Const(cExtraC0, width: cw) + eobCtxIdx.zeroExtend(cw))
          .getRange(0, cw);
      // The NONE 8x8 leaf has exactly ONE 4x4 chroma block per plane (U, V). In
      // a SINGLE SB it has NO above/left chroma neighbours, so the chroma dc_sign
      // ctx is always 0 (dc_sign sum 0 -> _dcSignContexts[32] = 0). In a TILE
      // (multiSb) the chroma block has cross-SB chroma neighbours, so the ctx is
      // neighbour-derived (chromaDcSignCtx). Either way the luma-neighbour
      // dcSignCtxV must NOT leak into the chroma context.
      dcSignCDecCtx = intraChromaEC
          ? chromaDcSign8Ctx!
          : (useChromaEC ? chromaDcSignCtx! : Const(cDcSignC0, width: cw));
    }

    // txLeaf TX_8X8 coeff combinational (shared window, 64-coeff block)
    // Mirrors HarborCoeffLevels(txSize:1): bhl=3, width=8, n=64, txsCtx=1.
    // Reuses the shared registers (cIdx, classReg, eob*, level*, golomb, pbLevel,
    // sign, dc_sign) and the shared dequant, only the geometry + CDF context
    // bases differ. Active only on the 8x8 NONE leaf.
    Logic? base8Flat,
        br8Flat,
        eobPt8Ctx,
        eobExtra8Ctx,
        txbSkip8Ctx,
        pbLevelCur8,
        posOfCidx8,
        dqCoeff8;
    // chroma8 (16x16-root 4:2:0) TX_8X8 chroma CDF flats: the same cc8-derived
    // contexts as the luma TX_8X8 flats but with the plane-1 bank bases.
    Logic? baseC8Flat, brC8Flat, eobExtraC8Ctx;
    int paddedIdx8(int pos) => pos + ((pos >> 3) << 2);
    int rasterOf8(int pos) => (pos & 7) * 8 + (pos >> 3);
    if (txLeaf) {
      // pos = scan8[cIdx] by class (2D / VERT mrow / HORIZ mcol).
      posOfCidx8 = mux(
        classReg.eq(Const(2, width: 2)),
        romSel(_mrow8, cIdx, 7),
        mux(
          classReg.eq(Const(1, width: 2)),
          romSel(_mcol8, cIdx, 7),
          romSel(_scan8, cIdx, 7),
        ),
      );
      final cc8 = HarborCoeffContext(txSize: 1, name: 'cc8');
      addSubModule(cc8);
      cc8.input('coeff_idx').srcConnection! <=
          posOfCidx8.getRange(0, cc8.input('coeff_idx').width);
      final cc8ScanW = cc8.input('scan_idx').width;
      cc8.input('scan_idx').srcConnection! <=
          (cc8ScanW <= cidxW
              ? cIdx.getRange(0, cc8ScanW)
              : cIdx.zeroExtend(cc8ScanW));
      cc8.input('tx_class').srcConnection! <= classReg;
      cc8.input('levels').srcConnection! <=
          [for (var i = bufLen8 - 1; i >= 0; i--) levels8[i]].concat();
      final baseEobCtx8 = cc8.output('base_eob_ctx');
      final base2dCtx8 = cc8.output('base_ctx_2d');
      final baseGenCtx8 = cc8.output('base_ctx_gen');
      final brEobCtx8 = cc8.output('br_ctx_eob');
      final br2dCtx8 = cc8.output('br_ctx_2d');
      final brGenCtx8 = cc8.output('br_ctx_gen');
      final class2d8 = classReg.eq(Const(0, width: 2));
      Logic baseEobFlat8() =>
          (Const(cBaseEob8_0, width: cw) + baseEobCtx8.zeroExtend(cw)).getRange(
            0,
            cw,
          );
      Logic baseFlatFor8(Logic ctx) =>
          (Const(cBase8_0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
      final base2dPath8 = mux(
        isC0c,
        baseFlatFor8(baseGenCtx8),
        baseFlatFor8(base2dCtx8),
      );
      final nonEob1Base8 = mux(
        class2d8,
        base2dPath8,
        baseFlatFor8(baseGenCtx8),
      );
      base8Flat = mux(isEobMinus1, baseEobFlat8(), nonEob1Base8);
      // 8x8 base nsyms == the 4x4 baseNsyms (3 for eob-1, else 4), reuse it.
      final br2dPath8 = mux(
        isC0c,
        brGenCtx8.zeroExtend(cw),
        br2dCtx8.zeroExtend(cw),
      );
      final nonEob1Br8 = mux(class2d8, br2dPath8, brGenCtx8.zeroExtend(cw));
      final brSubCtx8 = mux(isEobMinus1, brEobCtx8.zeroExtend(cw), nonEob1Br8);
      br8Flat = (Const(cBr8_0, width: cw) + brSubCtx8).getRange(0, cw);
      // chroma8 flats: reuse the cc8 contexts (same TX_8X8 geometry) with the
      // plane-1 bank bases. Chroma is always TX_CLASS_2D, but the cc8 ctx muxing
      // already resolves to the 2D path when classReg==0, so this is identical
      // in structure to the luma flats.
      if (chroma8) {
        Logic baseEobFlatC8() =>
            (Const(cBaseEobC8_0, width: cw) + baseEobCtx8.zeroExtend(cw))
                .getRange(0, cw);
        Logic baseFlatForC8(Logic ctx) =>
            (Const(cBaseC8_0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
        final base2dPathC8 = mux(
          isC0c,
          baseFlatForC8(baseGenCtx8),
          baseFlatForC8(base2dCtx8),
        );
        final nonEob1BaseC8 = mux(
          class2d8,
          base2dPathC8,
          baseFlatForC8(baseGenCtx8),
        );
        baseC8Flat = mux(isEobMinus1, baseEobFlatC8(), nonEob1BaseC8);
        brC8Flat = (Const(cBrC8_0, width: cw) + brSubCtx8).getRange(0, cw);
        eobExtraC8Ctx =
            (Const(cEobExtraC8_0, width: cw) + eobCtxIdx.zeroExtend(cw))
                .getRange(0, cw);
      }
      // eob_pt-64 ctx (2D vs 1D) and eob_extra-8 ctx.
      eobPt8Ctx = mux<Logic>(
        class2d8,
        Const(cEobPt8_2d, width: cw),
        Const(cEobPt8_1d, width: cw),
      );
      eobExtra8Ctx = (Const(cEobExtra8_0, width: cw) + eobCtxIdx.zeroExtend(cw))
          .getRange(0, cw);
      // txb_skip-8: for the whole-SB 8x8 leaf, planeBsize == txsize_to_bsize so
      // the libaom skip ctx is 0 (BLOCK_8X8 vs TX_8X8). ctx 150 + 0.
      txbSkip8Ctx = Const(cTxb8, width: cw);
      // phase-B current level = levels8[paddedIdx8(pos)].
      Logic cur = levels8[paddedIdx8(63)];
      for (var p = 62; p >= 0; p--) {
        cur = mux(
          posOfCidx8.eq(Const(p, width: 7)),
          levels8[paddedIdx8(p)],
          cur,
        );
      }
      pbLevelCur8 = cur;
      // dequant for the 8x8 phase-B (shift = av1_get_tx_scale(TX_8X8) = 0).
      final deq8 = HarborDequant(bitDepth: bitDepth, name: 'deq8');
      addSubModule(deq8);
      deq8.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deq8.input('dc_q').srcConnection! <= input('dc_q');
      deq8.input('ac_q').srcConnection! <= input('ac_q');
      deq8.input('is_dc').srcConnection! <= isC0pb;
      deq8.input('sign').srcConnection! <= signReg;
      deq8.input('shift').srcConnection! <= Const(0, width: 2);
      dqCoeff8 = deq8.output('dq_coeff');
    }

    // txLeaf TX_16X16 coeff combinational (256-coeff, txsCtx=2, 2D only)
    // Mirrors the 8x8 block but n=256, bhl=4, txsCtx=2, and 2D class ALWAYS (the
    // 16x16 intra ext-tx set DTT4_IDTX has no 1D types). Reuses the shared
    // registers + dequant, only geometry + CDF bases differ. Active only on a
    // 16x16 NONE leaf (tx16 config).
    Logic? base16Flat,
        br16Flat,
        eobPt16Ctx,
        eobExtra16Ctx,
        txbSkip16Ctx,
        pbLevelCur16,
        posOfCidx16,
        dqCoeff16;
    // chroma16 (32x32-root 4:2:0) TX_16X16 chroma CDF flats: same cc16 contexts
    // as the luma TX_16X16 flats but with the plane-1 (txsCtx 2) bank bases.
    Logic? baseC16Flat, brC16Flat, eobExtraC16Ctx;
    // 4:2:2 chroma TX_8X16 (planeType 1, txsCtx 2) flats + scan/level/dequant.
    Logic? baseC422Flat,
        brC422Flat,
        eobExtraC422Ctx,
        pbLevelCurC422,
        posOfCidxC422,
        dqCoeffC422;
    int paddedIdx16(int pos) => pos + ((pos >> 4) << 2);
    int rasterOf16(int pos) => (pos & 15) * 16 + (pos >> 4);
    if (tx16) {
      posOfCidx16 = romSel(_scan16, cIdx, 8); // 2D scan only
      final cc16 = HarborCoeffContext(txSize: 2, name: 'cc16');
      addSubModule(cc16);
      cc16.input('coeff_idx').srcConnection! <=
          posOfCidx16.getRange(0, cc16.input('coeff_idx').width);
      final cc16ScanW = cc16.input('scan_idx').width;
      cc16.input('scan_idx').srcConnection! <=
          (cc16ScanW <= cidxW
              ? cIdx.getRange(0, cc16ScanW)
              : cIdx.zeroExtend(cc16ScanW));
      cc16.input('tx_class').srcConnection! <= Const(0, width: 2); // 2D
      cc16.input('levels').srcConnection! <=
          [for (var i = bufLen16 - 1; i >= 0; i--) levels16[i]].concat();
      final baseEobCtx16 = cc16.output('base_eob_ctx');
      final base2dCtx16 = cc16.output('base_ctx_2d');
      final baseGenCtx16 = cc16.output('base_ctx_gen');
      final brEobCtx16 = cc16.output('br_ctx_eob');
      final brGenCtx16 = cc16.output('br_ctx_gen');
      final br2dCtx16 = cc16.output('br_ctx_2d');
      Logic baseEobFlat16() =>
          (Const(cBaseEob16_0, width: cw) + baseEobCtx16.zeroExtend(cw))
              .getRange(0, cw);
      Logic baseFlatFor16(Logic ctx) =>
          (Const(cBase16_0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
      // 2D: the c0 coeff uses the general ctx, others the 2d ctx.
      final base2dPath16 = mux(
        isC0c,
        baseFlatFor16(baseGenCtx16),
        baseFlatFor16(base2dCtx16),
      );
      base16Flat = mux(isEobMinus1, baseEobFlat16(), base2dPath16);
      final br2dPath16 = mux(
        isC0c,
        brGenCtx16.zeroExtend(cw),
        br2dCtx16.zeroExtend(cw),
      );
      final brSubCtx16 = mux(
        isEobMinus1,
        brEobCtx16.zeroExtend(cw),
        br2dPath16,
      );
      br16Flat = (Const(cBr16_0, width: cw) + brSubCtx16).getRange(0, cw);
      // chroma16 flats: reuse the cc16 2D contexts with the plane-1 bank bases.
      if (chroma16) {
        Logic baseEobFlatC16() =>
            (Const(cBaseEobC16_0, width: cw) + baseEobCtx16.zeroExtend(cw))
                .getRange(0, cw);
        Logic baseFlatForC16(Logic ctx) =>
            (Const(cBaseC16_0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
        final base2dPathC16 = mux(
          isC0c,
          baseFlatForC16(baseGenCtx16),
          baseFlatForC16(base2dCtx16),
        );
        baseC16Flat = mux(isEobMinus1, baseEobFlatC16(), base2dPathC16);
        brC16Flat = (Const(cBrC16_0, width: cw) + brSubCtx16).getRange(0, cw);
        eobExtraC16Ctx =
            (Const(cEobExtraC16_0, width: cw) + eobCtxIdx.zeroExtend(cw))
                .getRange(0, cw);
      }
      eobPt16Ctx = Const(cEobPt16, width: cw); // 2D only
      eobExtra16Ctx =
          (Const(cEobExtra16_0, width: cw) + eobCtxIdx.zeroExtend(cw)).getRange(
            0,
            cw,
          );
      txbSkip16Ctx = Const(cTxb16, width: cw); // 16x16 NONE leaf skip ctx 0
      Logic cur = levels16[paddedIdx16(255)];
      for (var p = 254; p >= 0; p--) {
        cur = mux(
          posOfCidx16.eq(Const(p, width: 8)),
          levels16[paddedIdx16(p)],
          cur,
        );
      }
      pbLevelCur16 = cur;
      final deq16 = HarborDequant(bitDepth: bitDepth, name: 'deq16');
      addSubModule(deq16);
      deq16.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deq16.input('dc_q').srcConnection! <= input('dc_q');
      deq16.input('ac_q').srcConnection! <= input('ac_q');
      deq16.input('is_dc').srcConnection! <= isC0pb;
      deq16.input('sign').srcConnection! <= signReg;
      deq16.input('shift').srcConnection! <=
          Const(0, width: 2); // area 256 -> 0
      dqCoeff16 = deq16.output('dq_coeff');
    }

    // 32x32 / 64x64 NONE leaf (tx32 config). One 32x32-geometry coeff datapath
    // (1024 coeffs, _scan32, 2D only). 64x64 caps its coeffs to this 32x32
    // region, so the SAME cc / buffer / scan serve both, only the CDF bank base
    // (txsCtx 3 vs 4) and dequant shift (1 vs 2) differ, muxed by leafIs64.
    Logic? base32bFlat,
        br32bFlat,
        eobPt32bCtx,
        eobExtra32bCtx,
        txbSkip32bCtx,
        pbLevelCur32b,
        posOfCidx32b,
        dqCoeff32b;
    int paddedIdx32(int pos) => pos + ((pos >> 5) << 2);
    int rasterOf32(int pos) => (pos & 31) * 32 + (pos >> 5);
    if (tx32) {
      posOfCidx32b = romSel(_scan32, cIdx, posW32); // 2D scan only
      final cc32 = HarborCoeffContext(txSize: 3, name: 'cc32');
      addSubModule(cc32);
      cc32.input('coeff_idx').srcConnection! <=
          posOfCidx32b.getRange(0, cc32.input('coeff_idx').width);
      final cc32ScanW = cc32.input('scan_idx').width;
      cc32.input('scan_idx').srcConnection! <=
          (cc32ScanW <= cidxW
              ? cIdx.getRange(0, cc32ScanW)
              : cIdx.zeroExtend(cc32ScanW));
      cc32.input('tx_class').srcConnection! <= Const(0, width: 2); // 2D
      cc32.input('levels').srcConnection! <=
          [for (var i = bufLen32 - 1; i >= 0; i--) levels32[i]].concat();
      final baseEobCtx32 = cc32.output('base_eob_ctx');
      final base2dCtx32 = cc32.output('base_ctx_2d');
      final baseGenCtx32 = cc32.output('base_ctx_gen');
      final brEobCtx32 = cc32.output('br_ctx_eob');
      final brGenCtx32 = cc32.output('br_ctx_gen');
      final br2dCtx32 = cc32.output('br_ctx_2d');
      // CDF bank base per leaf size (32x32 txsCtx=3 vs 64x64 txsCtx=4), br is
      // shared (group 3), eob_pt is shared (1024-bin).
      final baseBank = mux<Logic>(
        leafIs64,
        Const(cBase64_0, width: cw),
        Const(cBase32_0, width: cw),
      );
      final baseEobBank = mux<Logic>(
        leafIs64,
        Const(cBaseEob64_0, width: cw),
        Const(cBaseEob32_0, width: cw),
      );
      final eobExtraBank = mux<Logic>(
        leafIs64,
        Const(cEobExtra64_0, width: cw),
        Const(cEobExtra32_0, width: cw),
      );
      final txbBank = mux<Logic>(
        leafIs64,
        Const(cTxb64, width: cw),
        Const(cTxb32, width: cw),
      );
      Logic baseEobFlat32() =>
          (baseEobBank + baseEobCtx32.zeroExtend(cw)).getRange(0, cw);
      Logic baseFlatFor32(Logic ctx) =>
          (baseBank + ctx.zeroExtend(cw)).getRange(0, cw);
      final base2dPath32 = mux(
        isC0c,
        baseFlatFor32(baseGenCtx32),
        baseFlatFor32(base2dCtx32),
      );
      base32bFlat = mux(isEobMinus1, baseEobFlat32(), base2dPath32);
      final br2dPath32 = mux(
        isC0c,
        brGenCtx32.zeroExtend(cw),
        br2dCtx32.zeroExtend(cw),
      );
      final brSubCtx32 = mux(
        isEobMinus1,
        brEobCtx32.zeroExtend(cw),
        br2dPath32,
      );
      br32bFlat = (Const(cBr32_0, width: cw) + brSubCtx32).getRange(0, cw);
      eobPt32bCtx = Const(cEobPt32, width: cw); // 2D, 1024-bin (shared 32/64)
      eobExtra32bCtx = (eobExtraBank + eobCtxIdx.zeroExtend(cw)).getRange(
        0,
        cw,
      );
      txbSkip32bCtx = txbBank; // NONE leaf skip ctx 0
      Logic cur = levels32[paddedIdx32(1023)];
      for (var p = 1022; p >= 0; p--) {
        cur = mux(
          posOfCidx32b.eq(Const(p, width: posW32)),
          levels32[paddedIdx32(p)],
          cur,
        );
      }
      pbLevelCur32b = cur;
      final deq32 = HarborDequant(bitDepth: bitDepth, name: 'deq32');
      addSubModule(deq32);
      deq32.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deq32.input('dc_q').srcConnection! <= input('dc_q');
      deq32.input('ac_q').srcConnection! <= input('ac_q');
      deq32.input('is_dc').srcConnection! <= isC0pb;
      deq32.input('sign').srcConnection! <= signReg;
      // av1_get_tx_scale: 32x32 area 1024 -> 1, 64x64 area 4096 -> 2.
      deq32.input('shift').srcConnection! <=
          mux<Logic>(leafIs64, Const(2, width: 2), Const(1, width: 2));
      dqCoeff32b = deq32.output('dq_coeff');
    }

    // RECT coeff combinational (shared window, all six rect shapes)
    // Mirrors the 8x8 block but with one cc instance per rect geometry, muxed by
    // rectKindReg (0=8x4 1=4x8 2=16x8 3=8x16 4=16x4 5=4x16). Reuses the shared
    // eob/level/golomb/sign/dc_sign registers. CDF banks: kinds 0/1/4/5 use the
    // txsCtx=1 slice (cTxb8 / cBaseEob8_0 / cBase8_0 / cBr8_0 / cEobExtra8_0).
    // kinds 2/3 use the txsCtx=2 slice (cTxb16 / cBaseEob16_0 / cBase16_0 /
    // cBr16_0 / cEobExtra16_0). eob_pt: 8x4/4x8 -> eob_pt-32, 16x4/4x16 ->
    // eob_pt-64 (== the 8x8 leaf's cEobPt8), 16x8/8x16 -> eob_pt-128 (new).
    // dc_sign reuses cDcSign0, av1_get_tx_scale == 0 for every rect (area <= 256).
    // Active only when leafRect is set (a HORZ/VERT rect leaf).
    Logic? base32Flat,
        br32Flat,
        eobPt32Ctx,
        eobExtra32Ctx,
        txbSkip32Ctx,
        extTx32Ctx,
        pbLevelCur32,
        posOfCidx32,
        dqCoeff32;
    // per-kind paddedIdx (column-major: p + ((p>>bhl)<<2)) and raster (row*txw+col
    // with col=p>>bhl, row=p&((1<<bhl)-1)).
    // TX_8X4: bhl=2, TX_4X8: bhl=3.
    int paddedIdx84(int pos) => pos + ((pos >> 2) << 2);
    int rasterOf84(int pos) => (pos & 3) * 8 + (pos >> 2);
    int paddedIdx48(int pos) => pos + ((pos >> 3) << 2);
    int rasterOf48(int pos) => (pos & 7) * 4 + (pos >> 3);
    // TX_16X8: bhl=3, TX_8X16: bhl=4.
    int paddedIdx168(int pos) => pos + ((pos >> 3) << 2);
    int rasterOf168(int pos) => (pos & 7) * 16 + (pos >> 3);
    int paddedIdx816(int pos) => pos + ((pos >> 4) << 2);
    int rasterOf816(int pos) => (pos & 15) * 8 + (pos >> 4);
    // TX_16X4: bhl=2, TX_4X16: bhl=4.
    int paddedIdx164(int pos) => pos + ((pos >> 2) << 2);
    int rasterOf164(int pos) => (pos & 3) * 16 + (pos >> 2);
    int paddedIdx416(int pos) => pos + ((pos >> 4) << 2);
    int rasterOf416(int pos) => (pos & 15) * 4 + (pos >> 4);
    // 4:2:2 chroma TX_8X16 coeff combinational (128-coeff rect, txsCtx=2,
    // plane-1, 2D only). A dedicated TX_8X16 context (like cc16 for chroma16)
    // fed by levels8x16 + the 2D 8x16 up-right scan. Reuses the txsCtx=2 plane-1
    // base/br/eob_extra/base_eob banks (shared with chroma16) but the eob_pt-128
    // plane-1 bank. dc_sign / txb_skip are neighbour-derived (chromaDcSign8Ctx /
    // chromaSkip8Ctx with cSkipBase cTxbC16_0). dequant shift 0 (av1_get_tx_scale
    // TX_8X16 == 0).
    if (chroma422Leaf) {
      posOfCidxC422 = romSel(_scan8x16, cIdx, 8); // 2D scan only
      final ccC422 = HarborCoeffContext(txSize: 7, name: 'ccC422');
      addSubModule(ccC422);
      ccC422.input('coeff_idx').srcConnection! <=
          posOfCidxC422.getRange(0, ccC422.input('coeff_idx').width);
      final scW = ccC422.input('scan_idx').width;
      ccC422.input('scan_idx').srcConnection! <=
          (scW <= cidxW ? cIdx.getRange(0, scW) : cIdx.zeroExtend(scW));
      ccC422.input('tx_class').srcConnection! <= Const(0, width: 2); // 2D
      ccC422.input('levels').srcConnection! <=
          [for (var i = bufLenRectB - 1; i >= 0; i--) levels8x16[i]].concat();
      final beC = ccC422.output('base_eob_ctx');
      final b2C = ccC422.output('base_ctx_2d');
      final bgC = ccC422.output('base_ctx_gen');
      final brEC = ccC422.output('br_ctx_eob');
      final br2C = ccC422.output('br_ctx_2d');
      final brgC = ccC422.output('br_ctx_gen');
      Logic baseEobFlatC422() =>
          (Const(cBaseEobC16_0, width: cw) + beC.zeroExtend(cw)).getRange(
            0,
            cw,
          );
      Logic baseFlatForC422(Logic ctx) =>
          (Const(cBaseC16_0, width: cw) + ctx.zeroExtend(cw)).getRange(0, cw);
      final base2dPathC422 = mux(
        isC0c,
        baseFlatForC422(bgC),
        baseFlatForC422(b2C),
      );
      baseC422Flat = mux(isEobMinus1, baseEobFlatC422(), base2dPathC422);
      final br2dPathC422 = mux(isC0c, brgC.zeroExtend(cw), br2C.zeroExtend(cw));
      final brSubCtxC422 = mux(isEobMinus1, brEC.zeroExtend(cw), br2dPathC422);
      brC422Flat = (Const(cBrC16_0, width: cw) + brSubCtxC422).getRange(0, cw);
      eobExtraC422Ctx =
          (Const(cEobExtraC16_0, width: cw) + eobCtxIdx.zeroExtend(cw))
              .getRange(0, cw);
      Logic cur = levels8x16[paddedIdx816(127)];
      for (var p = 126; p >= 0; p--) {
        cur = mux(
          posOfCidxC422.eq(Const(p, width: 8)),
          levels8x16[paddedIdx816(p)],
          cur,
        );
      }
      pbLevelCurC422 = cur;
      final deqC422 = HarborDequant(bitDepth: bitDepth, name: 'deqC422');
      addSubModule(deqC422);
      deqC422.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deqC422.input('dc_q').srcConnection! <= input('dc_q');
      deqC422.input('ac_q').srcConnection! <= input('ac_q');
      deqC422.input('is_dc').srcConnection! <= isC0pb;
      deqC422.input('sign').srcConnection! <= signReg;
      deqC422.input('shift').srcConnection! <= Const(0, width: 2);
      dqCoeffC422 = deqC422.output('dq_coeff');
    }
    if (txLeaf) {
      final rk = rectKindReg!;
      Logic isK(int k) => rk.eq(Const(k, width: 3));
      final kindBig = isK(2) | isK(3); // txsCtx=2 (16x8/8x16)
      final class2d32 = classReg.eq(Const(0, width: 2));
      // pos = rect-scan[cIdx] by class (2D / VERT mrow / HORIZ mcol), per kind.
      Logic scanSel(List<int> d2, List<int> mr, List<int> mc, int w) => mux(
        classReg.eq(Const(2, width: 2)),
        romSel(mr, cIdx, w),
        mux(
          classReg.eq(Const(1, width: 2)),
          romSel(mc, cIdx, w),
          romSel(d2, cIdx, w),
        ),
      );
      final pos84 = scanSel(_scan8x4, _mrow8x4, _mcol8x4, 6);
      final pos48 = scanSel(_scan4x8, _mrow4x8, _mcol4x8, 6);
      final pos168 = scanSel(_scan16x8, _mrow16x8, _mcol16x8, 7);
      final pos816 = scanSel(_scan8x16, _mrow8x16, _mcol8x16, 7);
      final pos164 = scanSel(_scan16x4, _mrow16x4, _mcol16x4, 6);
      final pos416 = scanSel(_scan4x16, _mrow4x16, _mcol4x16, 6);
      posOfCidx32 = mux(
        isK(1),
        pos48.zeroExtend(7),
        mux(
          isK(2),
          pos168,
          mux(
            isK(3),
            pos816,
            mux(
              isK(4),
              pos164.zeroExtend(7),
              mux(isK(5), pos416.zeroExtend(7), pos84.zeroExtend(7)),
            ),
          ),
        ),
      );

      // one cc per rect geometry, each fed by its own levels buffer and pos.
      HarborCoeffContext mkCc(
        String nm,
        int txSize,
        Logic pos,
        List<Logic> lv,
      ) {
        final cc = HarborCoeffContext(txSize: txSize, name: nm);
        addSubModule(cc);
        cc.input('coeff_idx').srcConnection! <=
            pos.getRange(0, cc.input('coeff_idx').width);
        final sw = cc.input('scan_idx').width;
        cc.input('scan_idx').srcConnection! <=
            (sw <= cidxW ? cIdx.getRange(0, sw) : cIdx.zeroExtend(sw));
        cc.input('tx_class').srcConnection! <= classReg;
        cc.input('levels').srcConnection! <=
            [for (var i = lv.length - 1; i >= 0; i--) lv[i]].concat();
        return cc;
      }

      final cc84 = mkCc('cc84', 6, pos84, levels8x4);
      final cc48 = mkCc('cc48', 5, pos48, levels4x8);
      final cc164 = mkCc('cc164', 14, pos164, levels16x4);
      final cc416 = mkCc('cc416', 13, pos416, levels4x16);
      final cc168 = tx16 ? mkCc('cc168', 8, pos168, levels16x8) : null;
      final cc816 = tx16 ? mkCc('cc816', 7, pos816, levels8x16) : null;

      Logic ccSel(String port) {
        final big = tx16
            ? mux(
                isK(2),
                cc168!.output(port),
                mux(isK(3), cc816!.output(port), cc84.output(port)),
              )
            : cc84.output(port);
        return mux(
          isK(1),
          cc48.output(port),
          mux(isK(4), cc164.output(port), mux(isK(5), cc416.output(port), big)),
        );
      }

      final baseEobCtx32 = ccSel('base_eob_ctx');
      final base2dCtx32 = ccSel('base_ctx_2d');
      final baseGenCtx32 = ccSel('base_ctx_gen');
      final brEobCtx32 = ccSel('br_ctx_eob');
      final br2dCtx32 = ccSel('br_ctx_2d');
      final brGenCtx32 = ccSel('br_ctx_gen');
      // bank bases: txsCtx=1 (8x8 slice) or txsCtx=2 (16x16 slice).
      final baseBank = mux<Logic>(
        kindBig,
        Const(cBase16_0, width: cw),
        Const(cBase8_0, width: cw),
      );
      final brBank = mux<Logic>(
        kindBig,
        Const(cBr16_0, width: cw),
        Const(cBr8_0, width: cw),
      );
      final baseEobBank = mux<Logic>(
        kindBig,
        Const(cBaseEob16_0, width: cw),
        Const(cBaseEob8_0, width: cw),
      );
      final eobExtraBank = mux<Logic>(
        kindBig,
        Const(cEobExtra16_0, width: cw),
        Const(cEobExtra8_0, width: cw),
      );
      final txbBank = mux<Logic>(
        kindBig,
        Const(cTxb16, width: cw),
        Const(cTxb8, width: cw),
      );
      Logic baseEobFlat32() =>
          (baseEobBank + baseEobCtx32.zeroExtend(cw)).getRange(0, cw);
      Logic baseFlatFor32(Logic ctx) =>
          (baseBank + ctx.zeroExtend(cw)).getRange(0, cw);
      final base2dPath32 = mux(
        isC0c,
        baseFlatFor32(baseGenCtx32),
        baseFlatFor32(base2dCtx32),
      );
      final nonEob1Base32 = mux(
        class2d32,
        base2dPath32,
        baseFlatFor32(baseGenCtx32),
      );
      base32Flat = mux(isEobMinus1, baseEobFlat32(), nonEob1Base32);
      final br2dPath32 = mux(
        isC0c,
        brGenCtx32.zeroExtend(cw),
        br2dCtx32.zeroExtend(cw),
      );
      final nonEob1Br32 = mux(class2d32, br2dPath32, brGenCtx32.zeroExtend(cw));
      final brSubCtx32 = mux(
        isEobMinus1,
        brEobCtx32.zeroExtend(cw),
        nonEob1Br32,
      );
      br32Flat = (brBank + brSubCtx32).getRange(0, cw);
      // eob_pt: 16x8/8x16 -> eob_pt-128, 16x4/4x16 -> eob_pt-64 (cEobPt8),
      // 8x4/4x8 -> eob_pt-32.
      final eobPt64 = mux<Logic>(
        class2d32,
        Const(cEobPt8_2d, width: cw),
        Const(cEobPt8_1d, width: cw),
      );
      final eobPt128 = mux<Logic>(
        class2d32,
        Const(cEobPt128_2d, width: cw),
        Const(cEobPt128_1d, width: cw),
      );
      final eobPt32 = mux<Logic>(
        class2d32,
        Const(cEobPt32_2d, width: cw),
        Const(cEobPt32_1d, width: cw),
      );
      eobPt32Ctx = mux(
        kindBig,
        eobPt128,
        mux(isK(4) | isK(5), eobPt64, eobPt32),
      );
      eobExtra32Ctx = (eobExtraBank + eobCtxIdx.zeroExtend(cw)).getRange(0, cw);
      // txb_skip: rect planeBsize == txsize_to_bsize so the libaom skip ctx is 0
      // -> the txsCtx bank base.
      txbSkip32Ctx = txbBank;
      // ext-tx: 16x8/8x16 have squareTx == TX_8X8 (set 3, eset 1) -> reuse the
      // 8x8 leaf's ext-tx-by-mode bank cExtTx8_0, the others have squareTx ==
      // TX_4X4 -> reuse the 4x4 bank cExtTx0.
      extTx32Ctx = mux(
        kindBig,
        (Const(cExtTx8_0, width: cw) + extTxDir.zeroExtend(cw)).getRange(0, cw),
        (Const(cExtTx0, width: cw) + extTxDir.zeroExtend(cw)).getRange(0, cw),
      );
      // phase-B current level = levels<kind>[paddedIdx<kind>(pos)].
      Logic curOf(
        Logic pos,
        List<Logic> lv,
        int Function(int) pad,
        int n,
        int w,
      ) {
        Logic cur = lv[pad(n - 1)];
        for (var p = n - 2; p >= 0; p--) {
          cur = mux(pos.eq(Const(p, width: w)), lv[pad(p)], cur);
        }
        return cur;
      }

      final cur84 = curOf(pos84, levels8x4, paddedIdx84, 32, 6);
      final cur48 = curOf(pos48, levels4x8, paddedIdx48, 32, 6);
      final cur164 = curOf(pos164, levels16x4, paddedIdx164, 64, 6);
      final cur416 = curOf(pos416, levels4x16, paddedIdx416, 64, 6);
      final curBig = tx16
          ? mux(
              isK(2),
              curOf(pos168, levels16x8, paddedIdx168, 128, 7),
              mux(
                isK(3),
                curOf(pos816, levels8x16, paddedIdx816, 128, 7),
                cur84,
              ),
            )
          : cur84;
      pbLevelCur32 = mux(
        isK(1),
        cur48,
        mux(isK(4), cur164, mux(isK(5), cur416, curBig)),
      );
      // dequant for the rect phase-B: av1_get_tx_scale == 0 for all rect.
      final deq32 = HarborDequant(bitDepth: bitDepth, name: 'deq32');
      addSubModule(deq32);
      deq32.input('level').srcConnection! <= pbLevelReg.getRange(0, 20);
      deq32.input('dc_q').srcConnection! <= input('dc_q');
      deq32.input('ac_q').srcConnection! <= input('ac_q');
      deq32.input('is_dc').srcConnection! <= isC0pb;
      deq32.input('sign').srcConnection! <= signReg;
      deq32.input('shift').srcConnection! <= Const(0, width: 2);
      dqCoeff32 = deq32.output('dq_coeff');
    }

    output('leaf_count') <= leafCount;
    output('sym_count') <= symCount;
    output('chk') <= chk;
    output('above_ctx') <=
        [for (var i = ctxN - 1; i >= 0; i--) aboveCtx[i]].concat();
    output('left_ctx') <=
        [for (var i = ctxN - 1; i >= 0; i--) leftCtx[i]].concat();
    output('above_skip') <=
        [for (var i = ctxN - 1; i >= 0; i--) aboveSkip[i]].concat();
    output('above_ymode') <=
        [for (var i = ctxN - 1; i >= 0; i--) aboveYm[i]].concat();
    if (coeffPrefix) {
      output('leaf_ymodes') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) ymodeOut[i]].concat();
      output('leaf_angles') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) angleOut[i]].concat();
      if (enableFilterIntra) {
        output('leaf_use_filter_intra') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) fiUseOut[i]].concat();
        output('leaf_filter_intra_modes') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) fiModeOut[i]].concat();
      }
      if (enablePalette) {
        output('leaf_has_pal_y') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) palHasYOut[i]].concat();
        output('leaf_pal_y_size') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) palYSizeOut[i]].concat();
        output('leaf_pal_y_colors') <=
            [
              for (var i = maxLeafOut * 8 - 1; i >= 0; i--) palYColOut[i],
            ].concat();
        output('leaf_pal_y_mapchk') <=
            [
              for (var i = maxLeafOut - 1; i >= 0; i--) palYMapChkOut[i],
            ].concat();
        if (chroma) {
          output('leaf_has_pal_uv') <=
              [
                for (var i = maxLeafOut - 1; i >= 0; i--) palHasUVOut[i],
              ].concat();
          output('leaf_pal_uv_size') <=
              [
                for (var i = maxLeafOut - 1; i >= 0; i--) palUVSizeOut[i],
              ].concat();
          output('leaf_pal_u_colors') <=
              [
                for (var i = maxLeafOut * 8 - 1; i >= 0; i--) palUColOut[i],
              ].concat();
          output('leaf_pal_v_colors') <=
              [
                for (var i = maxLeafOut * 8 - 1; i >= 0; i--) palVColOut[i],
              ].concat();
          output('leaf_pal_uv_mapchk') <=
              [
                for (var i = maxLeafOut - 1; i >= 0; i--) palUVMapChkOut[i],
              ].concat();
        }
      }
      output('leaf_txtypes') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) txtypeOut[i]].concat();
      output('leaf_coeffs') <=
          [
            for (var i = maxLeafOut * leafCoeffN - 1; i >= 0; i--) coeffsOut[i],
          ].concat();
      if (txLeaf) {
        output('leaf_log2size') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) log2Out[i]].concat();
        output('leaf_rect_kinds') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) rectKindOut[i]].concat();
        output('leaf_tx_depth') <=
            [for (var i = maxLeafOut - 1; i >= 0; i--) txDepthOut[i]].concat();
        // swizzle list index 0 = MSB, emit sub-block 3 down to 0 so sub-block s
        // lands at [s*4 +: 4].
        output('leaf_sub_txtypes') <=
            [for (var i = 3; i >= 0; i--) subTxType[i]].concat();
      }
    }
    if (chroma) {
      output('leaf_uv_mode') <= uvModeReg;
      output('leaf_cfl_alpha_idx') <= cflIdxReg;
      output('leaf_cfl_signs') <= cflSignsReg;
      output('leaf_u_coeffs') <=
          [for (var i = chromaN - 1; i >= 0; i--) uCoeffsRam[i]].concat();
      output('leaf_v_coeffs') <=
          [for (var i = chromaN - 1; i >= 0; i--) vCoeffsRam[i]].concat();
      output('leaf_luma_txtypes') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) lumaTxOut[i]].concat();
      output('leaf_uv_modes') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) uvModeOut[i]].concat();
      output('leaf_uv_angles') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) uvAngleOut[i]].concat();
      output('leaf_cfl_alpha_idxs') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) cflIdxOut[i]].concat();
      output('leaf_cfl_signs_arr') <=
          [for (var i = maxLeafOut - 1; i >= 0; i--) cflSignsOut[i]].concat();
      output('leaf_u_coeffs_arr') <=
          [
            for (var i = maxLeafOut * chromaN - 1; i >= 0; i--) uCoeffsOut[i],
          ].concat();
      output('leaf_v_coeffs_arr') <=
          [
            for (var i = maxLeafOut * chromaN - 1; i >= 0; i--) vCoeffsOut[i],
          ].concat();
    }

    const sIdle = 0, sPreload = 1, sInit = 2, sPop = 3, sRead = 4, sReadCap = 5, sLeaf = 6, sSkipDec = 7, sSkipCap = 8, sYmDec = 9, sYmCap = 10, sAngChk = 11, sAngDec = 12, sAngCap = 13, sUpd = 14, sDone = 15, sTxbDec = 16, sTxbCap = 17, sExtTxDec = 18, sExtTxCap = 19, sEobPt = 20, sEobPtCap = 21, sExtra = 22, sExtraCap = 23, sByp = 24, sBypDec = 25, sBypCap = 26, sBaseDec = 27, sBaseCap = 28, sBrDec = 29, sBrCap = 30, sNext = 31, sPbCheck = 32, sPbSignLoad = 33, sPbSignDec = 34, sPbSignCap = 35, sPbGolChk = 36, sPbGolLeadLoad = 37, sPbGolLeadDec = 38, sPbGolLeadCap = 39, sPbGolReadLoad = 40, sPbGolReadDec = 41, sPbGolReadCap = 42, sPbDeq = 43, sPbNext = 44,
    // txLeaf: tx_size depth decode for the 8x8 NONE leaf (additive states).
    sTxSzDec = 45, sTxSzCap = 46,
    // chroma: uv_mode / cfl / angle_delta_uv (mode info), inserted between
    // angle_delta_y and tx_size, plus the U/V plane sequencing.
    sUvDec = 47, sUvCap = 48, sCflSignDec = 49, sCflSignCap = 50, sCflULoad = 51, sCflUDec = 52, sCflUCap = 53, sCflVLoad = 54, sCflVDec = 55, sCflVCap = 56, sAngUvChk = 57, sAngUvDec = 58, sAngUvCap = 59,
    // chroma U/V plane start (clears the 4x4 levels/coeffs, then enters the
    // shared TX_4X4 coeff path via sTxbDec with coeffPlane != 0).
    sChromaU = 60, sChromaV = 61,
    // tx-split (depth 1): boundary between the four TX_4X4 sub-blocks.
    sSplitNext = 62,
    // filter_intra: use_filter_intra (2-sym) then, if set, filter_intra_mode
    // (5-sym). Decoded after the chroma mode info, before tx_size.
    sFiDec = 63, sFiCap = 64, sFiModeDec = 65, sFiModeCap = 66,
    // PALETTE mode info + colours + tokens (enablePalette). Inserted after
    // the chroma mode info, before filter_intra, tokens run in afterMode
    // before tx_size.
    sPalYModeDec = 67, sPalYModeCap = 68, sPalYSizeDec = 69, sPalYSizeCap = 70, sPalUVModeChk = 71, sPalUVModeDec = 72, sPalUVModeCap = 73, sPalUVSizeDec = 74, sPalUVSizeCap = 75, sPalCacheStep = 76, sPalCacheCap = 77, sPalNewInit = 78, sPalNewFirstCap = 79, sPalBits2Cap = 80, sPalDeltaLoop = 81, sPalDeltaCap = 82, sPalMerge = 83, sPalColDone = 84, sPalVModeCap = 85, sPalVBits2Cap = 86, sPalVFirstCap = 87, sPalVDeltaLoop = 88, sPalVDeltaCap = 89, sPalVSignCap = 90, sPalVDirLoop = 91, sPalVDirCap = 92, sPalLit = 93, sPalLitDec = 94, sPalLitCap = 95, sPalTokInit = 96, sPalNSInit = 97, sPalNSCap = 98, sPalNSHiCap = 99, sPalTokStep = 100, sPalTokDec = 101, sPalTokCap = 102,
    // 16x16 depth-1: boundary between the four TX_8X8 sub-blocks.
    sSplit16Next = 103;
    final st = Logic(name: 'st', width: 7);
    output('done') <= st.eq(Const(sDone, width: 7));

    // PALETTE combinational signals (enablePalette).
    late Logic palBctx, palYModeCtx, palYSizeCtx, palUVModeCtx, palUVSizeCtx;
    late Logic palAOk,
        palLOk,
        palAszY,
        palLszY; // neighbour palette Y avail/size
    late Logic palAszUV, palLszUV;
    late Logic palNextVal, palAdvA, palAdvL, palMoreCache; // cache merge step
    late Logic palTokCtx; // color-index ctx from the wavefront submodule
    late Logic palTokOrderCi; // remapped index = color_order[decoded symbol]
    late Logic
    palTokColorCtxBank; // full color-index CDF ctx (bank+(n-2)*5+ctx)
    if (enablePalette) {
      palBctx = romSel(_palBsizeCtx, eb, 3);
      // neighbour availability for the palette cache: above blocked at the SB
      // top row (er==0), left blocked at the SB left column (ec2==0). (Single-SB
      // scope: multiSb palette-neighbour preservation is deferred.)
      palAOk = er.gt(Const(0, width: cW));
      palLOk = ec2.gt(Const(0, width: cW));
      final aColPacked = mux(
        palAOk,
        selList(abovePalCol, aAbs(ec2)),
        Const(0, width: 128),
      );
      final lColPacked = mux(
        palLOk,
        selList(leftPalCol, er),
        Const(0, width: 128),
      );
      palAszY = mux(palAOk, selList(abovePalY, aAbs(ec2)), Const(0, width: 4));
      palLszY = mux(palLOk, selList(leftPalY, er), Const(0, width: 4));
      palAszUV = mux(
        palAOk,
        selList(abovePalUV, aAbs(ec2)),
        Const(0, width: 4),
      );
      palLszUV = mux(palLOk, selList(leftPalUV, er), Const(0, width: 4));
      final modeCtx =
          (palAszY.gt(Const(0, width: 4)).zeroExtend(2) +
                  palLszY.gt(Const(0, width: 4)).zeroExtend(2))
              .getRange(0, 2);
      palYModeCtx =
          (Const(cPalYMode0, width: cw) +
                  (palBctx.zeroExtend(cw) * Const(3, width: cw)) +
                  modeCtx.zeroExtend(cw))
              .getRange(0, cw);
      palYSizeCtx = (Const(cPalYSize0, width: cw) + palBctx.zeroExtend(cw))
          .getRange(0, cw);
      palUVModeCtx =
          (Const(cPalUVMode0, width: cw) +
                  palYSizeReg!.gt(Const(0, width: 4)).zeroExtend(cw))
              .getRange(0, cw);
      palUVSizeCtx = (Const(cPalUVSize0, width: cw) + palBctx.zeroExtend(cw))
          .getRange(0, cw);
      // cache merge: plane byte offset (Y=0, U=8) then dynamic byte select.
      final off = mux<Logic>(
        palPlane!.eq(Const(0, width: 2)),
        Const(0, width: 5),
        Const(8, width: 5),
      );
      Logic selByte(Logic packed, Logic byteIdx) {
        Logic v = packed.getRange(15 * 8, 16 * 8);
        for (var i = 14; i >= 0; i--) {
          v = mux(
            byteIdx.eq(Const(i, width: 5)),
            packed.getRange(i * 8, i * 8 + 8),
            v,
          );
        }
        return v;
      }

      final aVal = selByte(
        aColPacked,
        (off + palAi!.zeroExtend(5)).getRange(0, 5),
      );
      final lVal = selByte(
        lColPacked,
        (off + palLi!.zeroExtend(5)).getRange(0, 5),
      );
      final moreA = palAn!.gt(Const(0, width: 4));
      final moreL = palLn!.gt(Const(0, width: 4));
      palMoreCache = moreA | moreL;
      final lLtA = lVal.lt(aVal);
      final bothLeft = moreA & moreL & lLtA;
      final onlyLeft = moreL & ~moreA;
      // take-left when (both & lVal<aVal) or (only left remains).
      final takeLeft = bothLeft | onlyLeft;
      palNextVal = mux(takeLeft, lVal, aVal);
      palAdvA = ~takeLeft & moreA; // advance above when taking above
      // advance left when taking left, or when taking above and lVal==aVal.
      palAdvL = takeLeft | (~takeLeft & moreA & moreL & lVal.eq(aVal));
      // wavefront token context (drive the palette_color_ctx submodule)
      final rr = (palTokI!.zeroExtend(6) - palTokJ!.zeroExtend(6)).getRange(
        0,
        6,
      );
      final ccc = palTokJ.zeroExtend(6);
      final pw = palPlaneW!.zeroExtend(6);
      final base = (rr * pw).getRange(0, 6);
      final baseUp = ((rr - Const(1, width: 6)) * pw).getRange(0, 6);
      Logic mapAt(Logic idx) =>
          selList(palMap, idx.getRange(0, 6)).zeroExtend(4);
      final ccPos = ccc.getRange(0, 6);
      final leftIdx = (base + ccc - Const(1, width: 6)).getRange(0, 6);
      final alIdx = (baseUp + ccc - Const(1, width: 6)).getRange(0, 6);
      final abIdx = (baseUp + ccc).getRange(0, 6);
      final ccGt0 = ccPos.gt(Const(0, width: 6));
      final rrGt0 = rr.gt(Const(0, width: 6));
      palCtxMod!.input('n').srcConnection! <= palN!;
      palCtxMod.input('left').srcConnection! <=
          mux(ccGt0, mapAt(leftIdx), Const(8, width: 4));
      palCtxMod.input('above_left').srcConnection! <=
          mux(ccGt0 & rrGt0, mapAt(alIdx), Const(8, width: 4));
      palCtxMod.input('above').srcConnection! <=
          mux(rrGt0, mapAt(abIdx), Const(8, width: 4));
      palTokCtx = palCtxMod.output('ctx');
      // full color-index CDF ctx: bank (Y/UV) + (n-2)*5 + wavefront ctx.
      final colBank = mux<Logic>(
        palTokPlane!.eq(Const(0, width: 1)),
        Const(cPalYColor0, width: cw),
        Const(cPalUVColor0, width: cw),
      );
      palTokColorCtxBank =
          (colBank +
                  ((palN.zeroExtend(cw) - Const(2, width: cw)) *
                      Const(5, width: cw)) +
                  palTokCtx.zeroExtend(cw))
              .getRange(0, cw);
      // color_order[decoded symbol]: remap the decoded index back to palette idx.
      final order = palCtxMod.output('color_order');
      Logic orderSel(Logic sy) {
        Logic v = order.getRange(7 * 3, 8 * 3);
        for (var i = 6; i >= 0; i--) {
          v = mux(
            sy.eq(Const(i, width: 4)),
            order.getRange(i * 3, i * 3 + 3),
            v,
          );
        }
        return v;
      }

      palTokOrderCi = orderSel(sym.getRange(0, 4));
    }

    Combinational([
      ecInit < Const(0),
      ecLoad < Const(0),
      ecDecode < Const(0),
      ecCtx < Const(0, width: cw),
      ecCdf < Const(0, width: maxSyms * 16),
      ecNsyms < Const(0, width: 5),
      Case(st, [
        CaseItem(Const(sPreload, width: 7), [
          ecLoad < Const(1),
          ecCtx < pli.getRange(0, cw),
          ecCdf < selPreloadCdf(pli),
          ecNsyms < selPreloadNsyms(pli),
        ]),
        CaseItem(Const(sInit, width: 7), [ecInit < Const(1)]),
        CaseItem(Const(sRead, width: 7), [
          ecDecode < Const(1),
          ecCtx < readCtxIdx,
        ]),
        CaseItem(Const(sSkipDec, width: 7), [
          ecDecode < Const(1),
          ecCtx < skipDecCtx,
        ]),
        CaseItem(Const(sYmDec, width: 7), [
          ecDecode < Const(1),
          ecCtx < ymDecCtx,
        ]),
        CaseItem(Const(sAngDec, width: 7), [
          ecDecode < Const(1),
          ecCtx < angDecCtx,
        ]),
        if (enableFilterIntra) ...[
          // use_filter_intra ctx = cFilterIntra0 + block-size enum (eb).
          CaseItem(Const(sFiDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                (Const(cFilterIntra0, width: cw) + eb.zeroExtend(cw)).getRange(
                  0,
                  cw,
                ),
          ]),
          // filter_intra_mode (5-sym) at the single cFilterIntraMode ctx.
          CaseItem(Const(sFiModeDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cFilterIntraMode, width: cw),
          ]),
        ],
        if (enablePalette) ...[
          CaseItem(Const(sPalYModeDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < palYModeCtx,
          ]),
          CaseItem(Const(sPalYSizeDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < palYSizeCtx,
          ]),
          CaseItem(Const(sPalUVModeDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < palUVModeCtx,
          ]),
          CaseItem(Const(sPalUVSizeDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < palUVSizeCtx,
          ]),
          CaseItem(Const(sPalTokDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < palTokColorCtxBank,
          ]),
          // literal-bit reader: load the fixed [16384,0] bypass CDF, then decode.
          CaseItem(Const(sPalLit, width: 7), [
            If(
              palLitCnt!.lt(palLitTarget!),
              then: [
                ecLoad < Const(1),
                ecCtx < Const(cBypass, width: cw),
                ecCdf < packCdf(const [16384, 0]),
                ecNsyms < Const(2, width: 5),
              ],
            ),
          ]),
          CaseItem(Const(sPalLitDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cBypass, width: cw),
          ]),
        ],
        if (chroma) ...[
          // uv_mode (14-sym) decoded from the preloaded ctx cUvMode0 + y_mode.
          CaseItem(Const(sUvDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                (Const(cUvMode0, width: cw) + ymReg.zeroExtend(cw)).getRange(
                  0,
                  cw,
                ),
          ]),
          // angle_delta_uv reuses the angle CDF bank (cAngle0 + uvIntra-1).
          CaseItem(Const(sAngUvDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                (Const(cAngle0, width: cw) +
                        (romSel(_uv2y, uvModeReg, 4) - Const(1, width: 4))
                            .zeroExtend(cw))
                    .getRange(0, cw),
          ]),
          // cfl_sign (8-sym) at ctx cCflSign.
          CaseItem(Const(sCflSignDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cCflSign, width: cw),
          ]),
          // cfl_alpha_u/v: decode from the PERSISTENT per-row alpha bank (ctx 0
          // -> cCflAlpha, ctx 1..5 -> cCflAlphaExt..). No reload, so the alpha
          // CDF adapts across the tile (matches libaom). The *Load states are
          // now no-op pass-throughs (kept for the unchanged FSM sequencing).
          CaseItem(Const(sCflULoad, width: 7), const []),
          CaseItem(Const(sCflUDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < cflAlphaBank(cflAlphaRowU!),
          ]),
          CaseItem(Const(sCflVLoad, width: 7), const []),
          CaseItem(Const(sCflVDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < cflAlphaBank(cflAlphaRowV!),
          ]),
        ],
        if (coeffPrefix) ...[
          // tx_size depth decode (txLeaf 8x8 leaf): ctx cTxSz0 + txCtx (= 0 for
          // the whole-SB NONE leaf), the preloaded CDF carries nsyms = 2.
          if (txLeaf)
            CaseItem(Const(sTxSzDec, width: 7), [
              ecDecode < Const(1),
              // rect leaf: neighbour-derived ctx, 8x8 NONE leaf: ctx 0, 16x16 /
              // 32x32 / 64x64 leaf: cat1/2/3 bank + neighbour tx-size ctx.
              ecCtx <
                  () {
                    final base16OrRect = tx16
                        ? mux(
                            leafIs16,
                            (Const(cTxSz16_0, width: cw) +
                                    tx16Ctx!.zeroExtend(cw))
                                .getRange(0, cw),
                            mux(
                              leafIsRect,
                              (mux<Logic>(
                                        leafRectCat1,
                                        Const(cTxSz16_0, width: cw),
                                        Const(cTxSz0, width: cw),
                                      ) +
                                      rectTxSizeCtx!.zeroExtend(cw))
                                  .getRange(0, cw),
                              Const(cTxSz0, width: cw),
                            ),
                          )
                        : mux(
                            leafIsRect,
                            (mux<Logic>(
                                      leafRectCat1,
                                      Const(cTxSz16_0, width: cw),
                                      Const(cTxSz0, width: cw),
                                    ) +
                                    rectTxSizeCtx!.zeroExtend(cw))
                                .getRange(0, cw),
                            Const(cTxSz0, width: cw),
                          );
                    if (!tx32) return base16OrRect;
                    final txszBank = mux<Logic>(
                      leafIs64,
                      Const(cTxSz64_0, width: cw),
                      Const(cTxSz32_0, width: cw),
                    );
                    final big = (txszBank + tx32Ctx!.zeroExtend(cw)).getRange(
                      0,
                      cw,
                    );
                    return mux(leafIs32 | leafIs64, big, base16OrRect);
                  }(),
            ]),
          CaseItem(Const(sTxbDec, width: 7), [
            ecDecode < Const(1),
            // 4x4 txb_skip ctx: cTxb (skipCtx 0) for a SPLIT 4x4 leaf, but the
            // neighbour-derived splitTxbSkipCtx for a depth-1 tx-split sub-block.
            ecCtx <
                () {
                  final c4 = txLeaf
                      ? mux(
                          splitActive!,
                          splitTxbSkipCtx!,
                          Const(cTxb, width: cw),
                        )
                      : Const(cTxb, width: cw);
                  // A 16x16 depth-1 sub-block is a TX_8X8 (leafTx=1) but with a
                  // neighbour-derived txb_skip ctx (split16SkipCtx) instead of the
                  // whole-block ctx 0 (txbSkip8Ctx).
                  // The whole-SB 8x8 leaf ctx defaults to cTxb8 when the 8x8
                  // context block was not set up (e.g. the coeff-prefix path).
                  final tx8Skip = txbSkip8Ctx ?? Const(cTxb8, width: cw);
                  final tx8Ctx = tx16
                      ? mux(split16Active!, split16SkipCtx!, tx8Skip)
                      : tx8Skip;
                  final luma = txLeaf ? mux(leafTx, tx8Ctx, c4) : c4;
                  // rect leaf luma uses the 32-wide rect txb_skip ctx, the chroma
                  // (U/V) plane is an isolated TX_4X4 block so isChroma must win
                  // over leafRect.
                  var lumaRect = txLeaf
                      ? mux(leafRect!, txbSkip32Ctx!, luma)
                      : luma;
                  if (tx16)
                    lumaRect = mux(leafTx16Reg!, txbSkip16Ctx!, lumaRect);
                  if (tx32)
                    lumaRect = mux(leafTx32Reg!, txbSkip32bCtx!, lumaRect);
                  // multiSb chroma: the chroma 4x4 TXB has neighbour-derived ctx
                  // (aboveEc + leftEc + 7) from the cross-SB chroma EC arrays, a
                  // single-SB / non-multiSb chroma config keeps the hardcoded const.
                  // chroma8/chroma16 (16x16/32x32-root) txb_skip is the plane-1
                  // txsCtx-1/2 bank, single-SB so no neighbour -> ctx 7 base.
                  final chromaCtx = chroma8
                      ? (intraChromaEC
                            ? chromaSkip8Ctx!
                            : Const(cTxbC8_0, width: cw))
                      : chroma16
                      ? (intraChromaEC
                            ? chromaSkip8Ctx!
                            : Const(cTxbC16_0, width: cw))
                      : chroma422Leaf
                      ? chromaSkip8Ctx! // TX_8X16, cSkipBase cTxbC16_0
                      : (useChromaEC
                            ? chromaSkipCtx!
                            : Const(cTxbC0, width: cw));
                  return chroma ? mux(isChroma, chromaCtx, lumaRect) : lumaRect;
                }(),
          ]),
          CaseItem(Const(sExtTxDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                () {
                  var ex = txLeaf
                      ? mux(
                          leafTx,
                          (Const(cExtTx8_0, width: cw) +
                                  extTxDir.zeroExtend(cw))
                              .getRange(0, cw),
                          (Const(cExtTx0, width: cw) + extTxDir.zeroExtend(cw))
                              .getRange(0, cw),
                        )
                      : (Const(cExtTx0, width: cw) + extTxDir.zeroExtend(cw))
                            .getRange(0, cw);
                  // rect leaf: 16x8/8x16 -> cExtTx8_0 bank, others -> cExtTx0
                  // (extTx32Ctx already encodes the right base per rect kind).
                  if (txLeaf) ex = mux(leafRect!, extTx32Ctx!, ex);
                  return tx16
                      ? mux(
                          leafTx16Reg!,
                          (Const(cExtTx16, width: cw) + extTxDir.zeroExtend(cw))
                              .getRange(0, cw),
                          ex,
                        )
                      : ex;
                }(),
          ]),
          CaseItem(Const(sEobPt, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                () {
                  final luma = txLeaf
                      ? mux(leafTx, eobPt8Ctx!, eobPtDecCtx)
                      : eobPtDecCtx;
                  var lumaRect = txLeaf
                      ? mux(leafRect!, eobPt32Ctx!, luma)
                      : luma;
                  if (tx16) lumaRect = mux(leafTx16Reg!, eobPt16Ctx!, lumaRect);
                  if (tx32)
                    lumaRect = mux(leafTx32Reg!, eobPt32bCtx!, lumaRect);
                  return chroma
                      ? mux(
                          isChroma,
                          chroma8
                              ? Const(cEobPtC8_2d, width: cw)
                              : chroma16
                              ? Const(cEobPtC16_2d, width: cw)
                              : chroma422Leaf
                              ? Const(cEobPtC422_2d, width: cw)
                              : Const(cEobPtC2d, width: cw),
                          lumaRect,
                        )
                      : lumaRect;
                }(),
          ]),
          CaseItem(Const(sExtra, width: 7), [
            If(
              offBits.gt(Const(0, width: 4)),
              then: [
                ecDecode < Const(1),
                ecCtx <
                    () {
                      final luma = txLeaf
                          ? mux(leafTx, eobExtra8Ctx!, eobExtraDecCtx)
                          : eobExtraDecCtx;
                      var lumaRect = txLeaf
                          ? mux(leafRect!, eobExtra32Ctx!, luma)
                          : luma;
                      if (tx16)
                        lumaRect = mux(leafTx16Reg!, eobExtra16Ctx!, lumaRect);
                      if (tx32) {
                        lumaRect = mux(leafTx32Reg!, eobExtra32bCtx!, lumaRect);
                      }
                      return chroma
                          ? mux(
                              isChroma,
                              chroma8
                                  ? eobExtraC8Ctx!
                                  : chroma16
                                  ? eobExtraC16Ctx!
                                  : chroma422Leaf
                                  ? eobExtraC422Ctx!
                                  : eobExtraCDecCtx!,
                              lumaRect,
                            )
                          : lumaRect;
                    }(),
              ],
            ),
          ]),
          CaseItem(Const(sByp, width: 7), [
            If(
              bypIdxReg.lt(offBitsReg),
              then: [
                ecLoad < Const(1),
                ecCtx < Const(cBypass, width: cw),
                ecCdf < packCdf(const [16384, 0]),
                ecNsyms < Const(2, width: 5),
              ],
            ),
          ]),
          CaseItem(Const(sBypDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cBypass, width: cw),
          ]),
          CaseItem(Const(sBaseDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                () {
                  final luma = txLeaf
                      ? mux(leafTx, base8Flat!, baseFlat)
                      : baseFlat;
                  var lumaRect = txLeaf
                      ? mux(leafRect!, base32Flat!, luma)
                      : luma;
                  if (tx16) lumaRect = mux(leafTx16Reg!, base16Flat!, lumaRect);
                  if (tx32)
                    lumaRect = mux(leafTx32Reg!, base32bFlat!, lumaRect);
                  return chroma
                      ? mux(
                          isChroma,
                          chroma8
                              ? baseC8Flat!
                              : chroma16
                              ? baseC16Flat!
                              : chroma422Leaf
                              ? baseC422Flat!
                              : baseCFlat!,
                          lumaRect,
                        )
                      : lumaRect;
                }(),
            ecNsyms < baseNsyms,
          ]),
          CaseItem(Const(sBrDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                () {
                  final luma = txLeaf ? mux(leafTx, br8Flat!, brFlat) : brFlat;
                  var lumaRect = txLeaf
                      ? mux(leafRect!, br32Flat!, luma)
                      : luma;
                  if (tx16) lumaRect = mux(leafTx16Reg!, br16Flat!, lumaRect);
                  if (tx32) lumaRect = mux(leafTx32Reg!, br32bFlat!, lumaRect);
                  return chroma
                      ? mux(
                          isChroma,
                          chroma8
                              ? brC8Flat!
                              : chroma16
                              ? brC16Flat!
                              : chroma422Leaf
                              ? brC422Flat!
                              : brCFlat!,
                          lumaRect,
                        )
                      : lumaRect;
                }(),
            ecNsyms < Const(4, width: 5),
          ]),
          // phase B: sign (dc_sign adaptive for DC, bypass for AC) + golomb.
          CaseItem(Const(sPbSignLoad, width: 7), [
            ecLoad < Const(1),
            ecCtx < Const(cBypass, width: cw),
            ecCdf < packCdf(const [16384, 0]),
            ecNsyms < Const(2, width: 5),
          ]),
          CaseItem(Const(sPbSignDec, width: 7), [
            ecDecode < Const(1),
            ecCtx <
                () {
                  // luma dc_sign ctx: the leaf-level dcSignDecCtx for a TX_8X8 /
                  // SPLIT-4x4 leaf, the within-leaf splitDcSignCtx for a depth-1
                  // tx-split sub-block.
                  final dcLuma = txLeaf
                      ? mux(
                          splitActive!,
                          splitDcSignCtx!,
                          tx16
                              ? mux(
                                  split16Active!,
                                  split16DcSignCtx!,
                                  dcSignDecCtx,
                                )
                              : dcSignDecCtx,
                        )
                      : dcSignDecCtx;
                  return mux(
                    isC0pb,
                    (chroma ? mux(isChroma, dcSignCDecCtx!, dcLuma) : dcLuma),
                    Const(cBypass, width: cw),
                  );
                }(),
          ]),
          CaseItem(Const(sPbGolLeadLoad, width: 7), [
            ecLoad < Const(1),
            ecCtx < Const(cBypass, width: cw),
            ecCdf < packCdf(const [16384, 0]),
            ecNsyms < Const(2, width: 5),
          ]),
          CaseItem(Const(sPbGolLeadDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cBypass, width: cw),
          ]),
          CaseItem(Const(sPbGolReadLoad, width: 7), [
            ecLoad < Const(1),
            ecCtx < Const(cBypass, width: cw),
            ecCdf < packCdf(const [16384, 0]),
            ecNsyms < Const(2, width: 5),
          ]),
          CaseItem(Const(sPbGolReadDec, width: 7), [
            ecDecode < Const(1),
            ecCtx < Const(cBypass, width: cw),
          ]),
        ],
      ]),
    ]);

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
    List<Conditional> plan(List<List<Logic>> leaves) => [
      for (var i = 0; i < leaves.length; i++) ...[
        lr[i] < leaves[i][0],
        lc[i] < leaves[i][1],
        lbs[i] < leaves[i][2],
      ],
      leafN < Const(leaves.length, width: 3),
      st < Const(sLeaf, width: 7),
    ];
    // After a transform block's coefficients fully decode: with chroma, the
    // luma plane (coeffPlane 0) advances to the U chroma block, U to V, V to the
    // leaf update, otherwise straight to the leaf update.
    // After the luma coeffs, only the chromaRef leaf sequences the U then V
    // chroma transform blocks, a non-chromaRef leaf (a SPLIT 4x4 that is not
    // the bottom-right) has no chroma and goes straight to the leaf update.
    // CHROMA per-TXB EC write (Stage 1, multiSb + chroma): after the U coeffs
    // finish (coeffPlane 1) write the chroma EC value (cul_level | dc_sign<<6) of
    // THIS SB's U block into aboveEcU[chromaCol] and leftEcU, after the V coeffs
    // (coeffPlane 2) write aboveEcV/leftEcV. A right/below SB then reads these.
    // Mirrors SW _setEntropyCtx for the chroma plane.
    List<Conditional> chromaEcWrite(List<Logic> aboveArr, Logic? leftReg) {
      if (!useChromaEC || leftReg == null) return const [];
      final ecVal = (culLevelReg.zeroExtend(8) | (dcSignReg.zeroExtend(8) << 6))
          .getRange(0, 8);
      final idx = chromaColIdx();
      return <Conditional>[
        for (var k = 0; k < aboveArr.length; k++)
          If(idx.eq(Const(k, width: idx.width)), then: [aboveArr[k] < ecVal]),
        leftReg < ecVal,
      ];
    }

    // INTRA-SB chroma EC write: after a chroma plane's coeffs finish, store this
    // 8x8 chroma block's EC value (cul_level | dc_sign<<6) into the plane's
    // above (columns aOff, aOff+1) and left (rows lOff, lOff+1) arrays, so the
    // NEXT chroma block in this SB reads them as its neighbours (SW
    // _setEntropyCtx over the 2x2 chroma 4x4 units of the TX_8X8 block).
    List<Conditional> chromaEcWrite8(
      List<Logic> aboveArr,
      List<Logic> leftArr,
    ) {
      if (!intraChromaEC) return const [];
      final ecVal = (culLevelReg.zeroExtend(8) | (dcSignReg.zeroExtend(8) << 6))
          .getRange(0, 8);
      final aOff = chromaAboveIdx((ec2 >> ssx).getRange(0, cW)); // ABS column
      final aw = aOff.width;
      final lOff = (er >> ssy).getRange(0, cW);
      // Write every chroma 4x4 unit the tx block spans: array index k is written
      // when k - aOff in [0, chromaUnitsW) (above) / [0, chromaUnitsH) (left).
      Logic spans(Logic off, int k, int span, int w) => List.generate(
        span,
        (u) => off.eq(Const(k - u, width: w)),
      ).reduce((a, b) => a | b);
      return <Conditional>[
        for (var k = 0; k < aboveArr.length; k++)
          If(spans(aOff, k, chromaUnitsW, aw), then: [aboveArr[k] < ecVal]),
        for (var k = 0; k < leftArr.length; k++)
          If(spans(lOff, k, chromaUnitsH, cW), then: [leftArr[k] < ecVal]),
      ];
    }

    Conditional coeffDoneInner() => chroma
        ? Case(
            coeffPlane!,
            [
              CaseItem(Const(0, width: 2), [
                // luma plane done: snapshot the LUMA EC before the U/V planes
                // overwrite culLevelReg/dcSignReg (used by the sUpd neighbour write).
                lumaEcReg! <
                    (culLevelReg.zeroExtend(8) | (dcSignReg.zeroExtend(8) << 6))
                        .getRange(0, 8),
                If(
                  chromaRefV,
                  then: [st < Const(sChromaU, width: 7)],
                  orElse: [st < Const(sUpd, width: 7)],
                ),
              ]),
              CaseItem(Const(1, width: 2), [
                ...chromaEcWrite(aboveEcU, leftEcU),
                ...chromaEcWrite8(aboveEcCU, leftEcCU),
                st < Const(sChromaV, width: 7),
              ]),
            ],
            defaultItem: [
              ...chromaEcWrite(aboveEcV, leftEcV),
              ...chromaEcWrite8(aboveEcCV, leftEcCV),
              st < Const(sUpd, width: 7),
            ],
          )
        : (st < Const(sUpd, width: 7));
    // A tx-split (depth 1) sub-block's coeffs are done: route to the split
    // boundary (EC propagation + next sub-block) instead of the leaf update.
    Conditional coeffDoneNext() => txLeaf
        ? If(
            splitActive!,
            then: [st < Const(sSplitNext, width: 7)],
            orElse: tx16
                ? [
                    If(
                      split16Active!,
                      then: [st < Const(sSplit16Next, width: 7)],
                      orElse: [coeffDoneInner()],
                    ),
                  ]
                : [coeffDoneInner()],
          )
        : coeffDoneInner();
    Logic rPlus(Logic v) => (nr + v).getRange(0, cW);
    Logic cPlus(Logic v) => (nc + v).getRange(0, cW);
    // After mode-info: with coeffPrefix, a non-skip leaf decodes the coeff
    // prefix (txb_skip + ext-tx), a skipped leaf has no residual (all_zero=1).
    // A leaf signals tx_size (read here) only at BLOCK_8X8 (eb == 3) under
    // txLeaf, smaller leaves keep the existing TX_4X4 coeff path. A skipped leaf
    // never reads tx_size and has no residual.
    final leafIs8 = txLeaf ? eb.eq(Const(3, width: 5)) : Const(0);
    // After angle_delta_y: with chroma, the leaf reads uv_mode/cfl/angle_uv
    // BEFORE tx_size, otherwise it proceeds straight to tx_size/coeffs.
    late List<Conditional> Function() afterMode;
    // End of ALL mode info (after y_mode/angle_y and the chroma uv_mode/cfl/
    // angle_uv). An eligible luma leaf (y_mode == DC, both block dims <= 32,
    // enableFilterIntra) codes use_filter_intra here (SW _decodeBlock position).
    // Otherwise it goes straight to tx_size (afterMode). filter_intra is only
    // allowed for DC (non-directional) blocks, so angReg is always the default 0
    // and no angle_delta interacts. Palette is off in this walk.
    late List<Conditional> Function() enterFilterIntra;
    // palette_mode_info gate (after ALL chroma mode info, before filter_intra):
    // an eligible leaf (8x8..64x64) codes has_palette_y (when y_mode == DC) and
    // has_palette_uv (when uv_mode == DC on a chromaRef leaf). Ends by entering
    // filter_intra (suppressed when a luma palette is present).
    late List<Conditional> Function() enterPalette;
    // palette_tokens gate (after filter_intra, before tx_size): reads the luma /
    // chroma colour-index maps when the respective palette is present.
    late List<Conditional> Function() enterTokens;
    // After angle_delta_y: a chromaRef leaf decodes uv_mode/cfl/angle_uv BEFORE
    // its luma tx_size/coeffs, a non-chromaRef leaf (SPLIT 4x4 that is not the
    // bottom-right) has no chroma mode info and proceeds straight to the palette
    // / filter_intra gate.
    List<Conditional> postAngleY() => chroma
        ? [
            If(
              chromaRefV,
              then: [st < Const(sUvDec, width: 7)],
              orElse: enterPalette(),
            ),
          ]
        : enterPalette();
    afterMode = () => coeffPrefix
        ? [
            // every leaf: leafTx16Reg defaults to leafIs16 (16x16 NONE), refined
            // to depth==0 at sTxSzCap. A non-16x16 leaf clears it.
            if (tx16) ...[
              leafTx16Reg! < leafIs16,
              // depth-1 split flags clear per leaf, sTxSzCap sets them on a
              // depth-1 16x16 leaf.
              split16Active! < Const(0),
              leaf16SplitReg! < Const(0),
            ],
            // every leaf: leafTx32Reg defaults to (leafIs32|leafIs64), refined
            // to depth==0 at sTxSzCap. A skipped big leaf keeps TX_32X32/64X64.
            if (tx32) leafTx32Reg! < (leafIs32 | leafIs64),
            If(
              skipReg,
              then: [
                allZeroReg < Const(1),
                txTypeReg < Const(0, width: 4),
                eobReg < Const(0, width: 11),
                if (txLeaf)
                  leafTx < leafIs8, // skipped 8x8 leaf is still TX_8X8
                // a skipped rect leaf records its rect geometry for sUpd (no tx
                // depth read: blockSignalsTxsize but txMode SELECT only reads the
                // depth when !skip, skip uses depthToTxSize(0) = the rect tx).
                if (txLeaf) ...[
                  leafRect! < leafIsRect,
                  rectVert! < leafRectVert,
                  rectKindReg! < leafRectKind,
                ],
                st < Const(sUpd, width: 7),
              ],
              orElse: [
                if (txLeaf)
                  // BLOCK_8X8 (eb 3) and the rect leaves (eb 1/2) both signal
                  // tx_size (read the depth to stay window-aligned). leafRect marks
                  // the rect geometry, leafTx is resolved at sTxSzCap (depth 0 ->
                  // TX_8X8 only when !rect). A sub-8x8 4x4 leaf keeps the 4x4 path.
                  If(
                    leafIs8 | leafIsRect | leafIs16 | leafIs32 | leafIs64,
                    then: txModeSelect
                        ? [
                            leafRect! < leafIsRect,
                            rectVert! < leafRectVert,
                            rectKindReg! < leafRectKind,
                            // decode tx_size depth first (TX_MODE_SELECT)
                            st < Const(sTxSzDec, width: 7),
                          ]
                        : [
                            // TX_MODE_LARGEST: no tx_size symbol is coded, the
                            // tx size is INFERRED as the largest for the block
                            // (depth 0). Resolve the depth-0 state
                            // directly (leafTx16Reg / leafTx32Reg already default
                            // to the leaf size above) and skip straight to the
                            // coeff path so no phantom symbol is read.
                            leafRect! < leafIsRect,
                            rectVert! < leafRectVert,
                            rectKindReg! < leafRectKind,
                            leafTx < leafIs8, // TX_8X8 for the square 8x8 leaf
                            txDepthReg! < Const(0, width: 2),
                            splitActive! < Const(0),
                            subBlk! < Const(0, width: 2),
                            st < Const(sTxbDec, width: 7),
                          ],
                    orElse: [
                      leafTx < Const(0), // sub-8x8 4x4 leaf: TX_4X4 path
                      leafRect < Const(0),
                      rectKindReg < Const(0, width: 3),
                      st < Const(sTxbDec, width: 7),
                    ],
                  )
                else
                  st < Const(sTxbDec, width: 7),
              ],
            ),
          ]
        : [st < Const(sUpd, width: 7)];

    // filter_intra gate: eligible iff y_mode == DC_PRED (0), both block dims
    // <= 32 (miWide/miHigh <= 8) AND no luma palette (palette suppresses
    // filter_intra). Ineligible leaves skip to palette tokens / tx_size.
    enterFilterIntra = () {
      if (!enableFilterIntra) return enterTokens();
      final fiSizeOk =
          romSel(_miWide, eb, 8).lte(Const(8, width: 8)) &
          romSel(_miHigh, eb, 8).lte(Const(8, width: 8));
      var fiAllowed = ymReg.eq(Const(0, width: 4)) & fiSizeOk;
      if (enablePalette) fiAllowed &= palYSizeReg!.eq(Const(0, width: 4));
      return <Conditional>[
        If(
          fiAllowed,
          then: [st < Const(sFiDec, width: 7)],
          orElse: enterTokens(),
        ),
      ];
    };
    // palette_mode_info: decode has_palette_y (if y_mode == DC) then chroma
    // palette, a non-eligible leaf goes straight to filter_intra.
    enterPalette = () {
      if (!enablePalette) return enterFilterIntra();
      final allowed = eb.gte(Const(3, width: 5)) & eb.lte(Const(12, width: 5));
      return <Conditional>[
        If(
          allowed,
          then: [
            If(
              ymReg.eq(Const(0, width: 4)),
              then: [st < Const(sPalYModeDec, width: 7)],
              orElse: [st < Const(sPalUVModeChk, width: 7)],
            ),
          ],
          orElse: enterFilterIntra(),
        ),
      ];
    };
    // palette_tokens: read the luma colour-index map (if palette Y), then the
    // chroma map (if palette UV), then proceed to tx_size (afterMode).
    enterTokens = () {
      if (!enablePalette) return afterMode();
      return <Conditional>[
        If(
          palYSizeReg!.gt(Const(0, width: 4)),
          then: [
            palTokPlane! < Const(0, width: 1),
            st < Const(sPalTokInit, width: 7),
          ],
          orElse: [
            if (chroma)
              If(
                palUVSizeReg!.gt(Const(0, width: 4)),
                then: [
                  palTokPlane < Const(1, width: 1),
                  st < Const(sPalTokInit, width: 7),
                ],
                orElse: afterMode(),
              )
            else
              ...afterMode(),
          ],
        ),
      ];
    };

    // level-write into the (padded) levels buffer at the current scan position.
    // 4x4 writes `levels`, 8x8 writes `levels8`, gated by leafTx so only the
    // active geometry fires (the inactive posOfCidx never matches its range).
    List<Conditional> writeLevelAt(Logic value) {
      final w4 = <Conditional>[
        for (var p = 0; p < 16; p++)
          If(
            posOfCidx.eq(Const(p, width: 6)),
            then: [levels[paddedIdx(p)] < cap8(value)],
          ),
      ];
      if (!txLeaf) return w4;
      final w8 = <Conditional>[
        for (var p = 0; p < 64; p++)
          If(
            posOfCidx8!.eq(Const(p, width: 7)),
            then: [levels8[paddedIdx8(p)] < cap8(value)],
          ),
      ];
      // rect: write the active rect kind's level buffer at posOfCidx32 (7-bit).
      List<Conditional> rectLvlW(
        List<Logic> lv,
        int Function(int) pad,
        int n,
      ) => [
        for (var p = 0; p < n; p++)
          If(
            posOfCidx32!.eq(Const(p, width: 7)),
            then: [lv[pad(p)] < cap8(value)],
          ),
      ];
      final w32 = <Conditional>[
        If(
          rectKindReg!.eq(Const(1, width: 3)),
          then: rectLvlW(levels4x8, paddedIdx48, 32),
          orElse: [
            If(
              rectKindReg.eq(Const(4, width: 3)),
              then: rectLvlW(levels16x4, paddedIdx164, 64),
              orElse: [
                If(
                  rectKindReg.eq(Const(5, width: 3)),
                  then: rectLvlW(levels4x16, paddedIdx416, 64),
                  orElse: tx16
                      ? [
                          If(
                            rectKindReg.eq(Const(2, width: 3)),
                            then: rectLvlW(levels16x8, paddedIdx168, 128),
                            orElse: [
                              If(
                                rectKindReg.eq(Const(3, width: 3)),
                                then: rectLvlW(levels8x16, paddedIdx816, 128),
                                orElse: rectLvlW(levels8x4, paddedIdx84, 32),
                              ),
                            ],
                          ),
                        ]
                      : rectLvlW(levels8x4, paddedIdx84, 32),
                ),
              ],
            ),
          ],
        ),
      ];
      // chroma planes are TX_4X4: only the 8x8 luma block (leafTx & !isChroma)
      // writes the 8x8 levels buffer. A rect leaf (leafRect) writes the rect
      // buffer for its LUMA plane, but its chroma (U/V) plane is an isolated
      // TX_4X4 block, so isChroma must win over leafRect and route to the 4x4
      // levels. A fresh w4 list (a Conditional cannot live in two branches).
      final use8 = chroma ? (leafTx & ~isChroma) : leafTx;
      final lumaRect = If(
        leafRect!,
        then: w32,
        orElse: [If(use8, then: w8, orElse: w4)],
      );
      // a 16x16 leaf writes its 256-entry levels16 buffer (wins over rect/8x8).
      final w16 = tx16
          ? <Conditional>[
              for (var p = 0; p < 256; p++)
                If(
                  posOfCidx16!.eq(Const(p, width: 8)),
                  then: [levels16[paddedIdx16(p)] < cap8(value)],
                ),
            ]
          : <Conditional>[];
      final lumaSized16 = tx16
          ? If(leafTx16Reg!, then: w16, orElse: [lumaRect])
          : lumaRect;
      // a 32x32 / 64x64 leaf writes its 1024-entry levels32 buffer (wins over
      // 16x16/rect/8x8). 64x64 caps coeffs to the 32x32 region, so one buffer.
      final wBig = tx32
          ? <Conditional>[
              for (var p = 0; p < 1024; p++)
                If(
                  posOfCidx32b!.eq(Const(p, width: posW32)),
                  then: [levels32[paddedIdx32(p)] < cap8(value)],
                ),
            ]
          : <Conditional>[];
      final lumaSized = tx32
          ? If(leafTx32Reg!, then: wBig, orElse: [lumaSized16])
          : lumaSized16;
      if (!chroma) return [lumaSized];
      // chroma8 (16x16-root) chroma plane is TX_8X8 -> writes the 8x8 levels
      // buffer (posOfCidx8), a fresh copy since a Conditional cannot live in two
      // branches (w8 above is the luma-plane copy).
      if (chroma8) {
        final w8c = <Conditional>[
          for (var p = 0; p < 64; p++)
            If(
              posOfCidx8!.eq(Const(p, width: 7)),
              then: [levels8[paddedIdx8(p)] < cap8(value)],
            ),
        ];
        return [
          If(isChroma, then: w8c, orElse: [lumaSized]),
        ];
      }
      if (chroma16) {
        // chroma plane is TX_16X16 -> writes the 256-entry levels16 buffer.
        final w16c = <Conditional>[
          for (var p = 0; p < 256; p++)
            If(
              posOfCidx16!.eq(Const(p, width: 8)),
              then: [levels16[paddedIdx16(p)] < cap8(value)],
            ),
        ];
        return [
          If(isChroma, then: w16c, orElse: [lumaSized]),
        ];
      }
      if (chroma422Leaf) {
        // chroma plane is TX_8X16 -> writes the 8x16 levels buffer.
        final w816c = <Conditional>[
          for (var p = 0; p < 128; p++)
            If(
              posOfCidxC422!.eq(Const(p, width: 8)),
              then: [levels8x16[paddedIdx816(p)] < cap8(value)],
            ),
        ];
        return [
          If(isChroma, then: w816c, orElse: [lumaSized]),
        ];
      }
      final w4c = <Conditional>[
        for (var p = 0; p < 16; p++)
          If(
            posOfCidx.eq(Const(p, width: 6)),
            then: [levels[paddedIdx(p)] < cap8(value)],
          ),
      ];
      return [
        If(isChroma, then: w4c, orElse: [lumaSized]),
      ];
    }

    // Start a literal-bit read of `target` bits (MSB-first) into palLitAcc, then
    // jump to state `ret`. `target` is either a compile-time int or a Logic.
    List<Conditional> startLit(int? targetC, Logic? targetL, int ret) => [
      palLitAcc! < Const(0, width: 16),
      palLitCnt! < Const(0, width: 5),
      palLitTarget! <
          (targetL != null
              ? targetL.getRange(0, 5)
              : Const(targetC!, width: 5)),
      palLitRet! < Const(ret, width: 7),
      st < Const(sPalLit, width: 7),
    ];

    Sequential(clk, [
      If(
        reset,
        then: [
          st < Const(sIdle, width: 7),
          cursor < Const(0, width: cursor.width),
          sp < Const(0, width: spW),
          pli < Const(0, width: pliW),
          leafCount < Const(0, width: 12),
          symCount < Const(0, width: 12),
          chk < Const(0, width: 32),
          nr < Const(0, width: cW),
          nc < Const(0, width: cW),
          nbs < Const(0, width: 5),
          leafN < Const(0, width: 3),
          emitIdx < Const(0, width: 3),
          aboveOpenReg < Const(0),
          leftOpenReg < Const(0),
          skipReg < Const(0),
          ymReg < Const(0, width: 4),
          angReg < Const(0, width: 3),
          angUvReg < Const(0, width: 3),
          if (enableFilterIntra) ...[
            fiReg! < Const(0),
            fiModeReg! < Const(0, width: 3),
          ],
          allZeroReg < Const(0),
          txTypeReg < Const(0, width: 4),
          classReg < Const(0, width: 2),
          eobPtReg < Const(0, width: 4),
          eobExtraReg < Const(0, width: 11),
          offBitsReg < Const(0, width: 4),
          bypIdxReg < Const(0, width: 4),
          eobReg < Const(0, width: 11),
          cIdx < Const(0, width: cidxW),
          levelReg < Const(0, width: 8),
          brIdxReg < Const(0, width: 3),
          signReg < Const(0),
          pbLevelReg < Const(0, width: 21),
          golLeadReg < Const(0, width: 6),
          golXReg < Const(0, width: 21),
          golCntReg < Const(0, width: 6),
          culLevelReg < Const(0, width: 7),
          dcSignReg < Const(0, width: 2),
          if (chroma) lumaEcReg! < Const(0, width: 8),
          for (var i = 0; i < bufLen; i++) levels[i] < Const(0, width: 8),
          for (var i = 0; i < leafCoeffN; i++)
            coeffsRam[i] < Const(0, width: coefW),
          leafTx < Const(0),
          if (tx16) ...[
            leafTx16Reg! < Const(0),
            split16Active! < Const(0),
            leaf16SplitReg! < Const(0),
            for (var i = 0; i < bufLen16; i++) levels16[i] < Const(0, width: 8),
          ],
          if (tx32) ...[
            leafTx32Reg! < Const(0),
            for (var i = 0; i < bufLen32; i++) levels32[i] < Const(0, width: 8),
          ],
          if (txLeaf) ...[
            for (var i = 0; i < bufLen8; i++) levels8[i] < Const(0, width: 8),
            for (var i = 0; i < bufLenRect; i++) ...[
              levels8x4[i] < Const(0, width: 8),
              levels4x8[i] < Const(0, width: 8),
            ],
            for (var i = 0; i < bufLenRectC; i++) ...[
              levels16x4[i] < Const(0, width: 8),
              levels4x16[i] < Const(0, width: 8),
            ],
            if (tx16)
              for (var i = 0; i < bufLenRectB; i++) ...[
                levels16x8[i] < Const(0, width: 8),
                levels8x16[i] < Const(0, width: 8),
              ],
            leafRect! < Const(0),
            rectVert! < Const(0),
            rectKindReg! < Const(0, width: 3),
            for (var i = 0; i < maxLeafOut; i++) ...[
              log2Out[i] < Const(0, width: 3),
              rectKindOut[i] < Const(0, width: 3),
              txDepthOut[i] < Const(0, width: 2),
            ],
            txDepthReg! < Const(0, width: 2),
            splitActive! < Const(0),
            subBlk! < Const(0, width: 2),
            for (var i = 0; i < 4; i++) subTxType[i] < Const(0, width: 4),
            for (var i = 0; i < 2; i++) ...[
              subAboveEC[i] < Const(0, width: 8),
              subLeftEC[i] < Const(0, width: 8),
            ],
            for (var i = 0; i < ctxN; i++) leftTxfm[i] < Const(0, width: 7),
            for (var i = 0; i < aboveCtxN; i++)
              aboveTxfm[i] < Const(0, width: 7),
          ],
          if (chroma) ...[
            uvModeReg < Const(0, width: 4),
            cflIdxReg < Const(0, width: 8),
            cflSignsReg < Const(0, width: 3),
            coeffPlane! < Const(0, width: 2),
            for (var i = 0; i < chromaN; i++) ...[
              uCoeffsRam[i] < Const(0, width: coefW),
              vCoeffsRam[i] < Const(0, width: coefW),
            ],
            for (var i = 0; i < maxLeafOut; i++)
              lumaTxOut[i] < Const(0, width: 4),
            for (var i = 0; i < maxLeafOut; i++) ...[
              uvModeOut[i] < Const(0, width: 4),
              uvAngleOut[i] < Const(0, width: 3),
              cflIdxOut[i] < Const(0, width: 8),
              cflSignsOut[i] < Const(0, width: 3),
            ],
            for (var i = 0; i < maxLeafOut * chromaN; i++) ...[
              uCoeffsOut[i] < Const(0, width: coefW),
              vCoeffsOut[i] < Const(0, width: coefW),
            ],
          ],
          for (var i = 0; i < maxLeafOut; i++) ...[
            ymodeOut[i] < Const(0, width: 4),
            angleOut[i] < Const(0, width: 3),
            if (enableFilterIntra) ...[
              fiUseOut[i] < Const(0),
              fiModeOut[i] < Const(0, width: 3),
            ],
            txtypeOut[i] < Const(0, width: 4),
          ],
          for (var i = 0; i < maxLeafOut * leafCoeffN; i++)
            coeffsOut[i] < Const(0, width: coefW),
          for (var i = 0; i < ctxN; i++) leftEC[i] < Const(0, width: 8),
          for (var i = 0; i < aboveCtxN; i++) aboveEC[i] < Const(0, width: 8),
          if (useChromaEC) ...[
            for (var i = 0; i < aboveChromaN; i++) ...[
              aboveEcU[i] < Const(0, width: 8),
              aboveEcV[i] < Const(0, width: 8),
            ],
            leftEcU! < Const(0, width: 8),
            leftEcV! < Const(0, width: 8),
          ],
          if (intraChromaEC) ...[
            for (var i = 0; i < chromaEcAboveN; i++) ...[
              aboveEcCU[i] < Const(0, width: 8),
              aboveEcCV[i] < Const(0, width: 8),
            ],
            for (var i = 0; i < chromaEcLeftN; i++) ...[
              leftEcCU[i] < Const(0, width: 8),
              leftEcCV[i] < Const(0, width: 8),
            ],
          ],
          for (var i = 0; i < ctxN; i++) ...[
            leftCtx[i] < Const(0, width: 5),
            leftSkip[i] < Const(0),
            leftYm[i] < Const(0, width: 4),
            if (enablePalette) ...[
              leftPalY[i] < Const(0, width: 4),
              leftPalUV[i] < Const(0, width: 4),
              leftPalCol[i] < Const(0, width: 128),
            ],
          ],
          for (var i = 0; i < aboveCtxN; i++) ...[
            aboveCtx[i] < Const(0, width: 5),
            aboveSkip[i] < Const(0),
            aboveYm[i] < Const(0, width: 4),
            if (enablePalette) ...[
              abovePalY[i] < Const(0, width: 4),
              abovePalUV[i] < Const(0, width: 4),
              abovePalCol[i] < Const(0, width: 128),
            ],
          ],
          if (enablePalette) ...[
            palYSizeReg! < Const(0, width: 4),
            palUVSizeReg! < Const(0, width: 4),
            palMapChkY! < Const(0, width: 32),
            palMapChkUV! < Const(0, width: 32),
            palHaveLast! < Const(0),
            palTokPlane! < Const(0, width: 1),
            palN! < Const(0, width: 4),
            palIdx! < Const(0, width: 4),
            palMi! < Const(0, width: 4),
            palTokI! < Const(0, width: 5),
            palTokJ! < Const(0, width: 5),
            for (var i = 0; i < 8; i++) ...[
              palColY[i] < Const(0, width: 8),
              palColU[i] < Const(0, width: 8),
              palColV[i] < Const(0, width: 8),
              palCached[i] < Const(0, width: 8),
              palNew[i] < Const(0, width: 8),
            ],
            for (var i = 0; i < 64; i++) palMap[i] < Const(0, width: 4),
          ],
          sbColMi < Const(0, width: colW),
          for (var i = 0; i < dStack; i++) ...[
            stR[i] < Const(0, width: cW),
            stC[i] < Const(0, width: cW),
            stB[i] < Const(0, width: 5),
          ],
          for (var i = 0; i < maxBytes; i++) buf[i] < Const(0, width: 8),
        ],
        orElse: [
          cursor <
              (cursor + bytePop.zeroExtend(cursor.width)).getRange(
                0,
                cursor.width,
              ),
          Case(st, [
            CaseItem(Const(sIdle, width: 7), [
              If(
                input('start'),
                then: [
                  // Latch the SB's tile-relative top-edge availability and clear the
                  // per-SB leaf/sym/chk accumulators (the verification surface is
                  // PER-SB so the continued SB's stream is checked on its own).
                  aboveOpenReg < aboveOpenIn,
                  leftOpenReg < leftOpenIn,
                  // Latch this SB's tile-column MI offset (Increment 2). The above-*
                  // arrays index by sbColMi + local column, so the SB writes/reads
                  // its own tile-width band. 0 when not multiSb.
                  sbColMi <
                      (multiSb && tileMiW != 0
                          ? input('sb_c_mi').getRange(0, colW)
                          : Const(0, width: colW)),
                  leafCount < Const(0, width: 12),
                  symCount < Const(0, width: 12),
                  chk < Const(0, width: 32),
                  // LEFT-* arrays are cleared at every SB column start (single-SB or
                  // VERTICAL continuation): a fresh SB column has no in-SB left
                  // neighbours. EXCEPTION (HORIZONTAL continuation, `cont_left`):
                  // the next SB is to the RIGHT in the same SB row, so the left-*
                  // context PERSISTS (AV1 clears it only per SB row at the
                  // tile-left). When `cont_left` is set the clear is skipped.
                  If(
                    ~contLeftIn,
                    then: [
                      for (var i = 0; i < ctxN; i++) ...[
                        leftCtx[i] < Const(0, width: 5),
                        leftSkip[i] < Const(0),
                        leftYm[i] < Const(0, width: 4),
                        if (coeffPrefix) leftEC[i] < Const(0, width: 8),
                        if (txLeaf) leftTxfm[i] < Const(0, width: 7),
                      ],
                      // chroma left EC: cleared per SB column UNLESS cont_left (a
                      // RIGHT-neighbour SB in the same SB row preserves it).
                      if (useChromaEC) ...[
                        leftEcU! < Const(0, width: 8),
                        leftEcV! < Const(0, width: 8),
                      ],
                      // intra-SB chroma8 LEFT EC (per chroma row): same rule, cleared
                      // at a tile-left SB column, PRESERVED on cont_left so the SB to
                      // the right reads this SB's right-edge chroma EC per row.
                      if (intraChromaEC)
                        for (var i = 0; i < chromaEcLeftN; i++) ...[
                          leftEcCU[i] < Const(0, width: 8),
                          leftEcCV[i] < Const(0, width: 8),
                        ],
                    ],
                  ),
                  // Partition stack seeded with the root SB (both paths).
                  stR[0] < Const(0, width: cW),
                  stC[0] < Const(0, width: cW),
                  stB[0] < Const(rootBsize, width: 5),
                  sp < Const(1, width: spW),
                  If(
                    contIn,
                    then: [
                      // CONTINUE: keep the SAME window (no `bytes` reload, no `cursor`
                      // reset) and the SAME adapted CDFs (skip sPreload + sInit), and
                      // PRESERVE the above-* arrays (they hold the previous SB-row's
                      // bottom edge). Jump straight to popping the partition stack.
                      st < Const(sPop, width: 7),
                    ],
                    orElse: [
                      // FRESH start: reload the window bytes, restart the od_ec window
                      // (sInit), reload default CDFs (sPreload), and clear the above-*
                      // arrays. Byte-identical to the original single-SB behaviour.
                      for (var i = 0; i < maxBytes; i++)
                        buf[i] < input('bytes').getRange(i * 8, i * 8 + 8),
                      cursor < Const(0, width: cursor.width),
                      pli < Const(0, width: pliW),
                      for (var i = 0; i < aboveCtxN; i++) ...[
                        aboveCtx[i] < Const(0, width: 5),
                        aboveSkip[i] < Const(0),
                        aboveYm[i] < Const(0, width: 4),
                        if (coeffPrefix) aboveEC[i] < Const(0, width: 8),
                        if (txLeaf) aboveTxfm[i] < Const(0, width: 7),
                      ],
                      // chroma above EC: cleared on a FRESH start, PRESERVED on cont
                      // (a BELOW-neighbour SB row reads the previous row's chroma EC).
                      if (useChromaEC)
                        for (var i = 0; i < aboveChromaN; i++) ...[
                          aboveEcU[i] < Const(0, width: 8),
                          aboveEcV[i] < Const(0, width: 8),
                        ],
                      // intra-SB chroma8 ABOVE EC (tile-wide): cleared on a FRESH start,
                      // PRESERVED on cont so an SB below reads the SB-above's bottom
                      // chroma edge (first SB row: untouched cols stay 0 => no above).
                      if (intraChromaEC)
                        for (var i = 0; i < chromaEcAboveN; i++) ...[
                          aboveEcCU[i] < Const(0, width: 8),
                          aboveEcCV[i] < Const(0, width: 8),
                        ],
                      st < Const(sPreload, width: 7),
                    ],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sPreload, width: 7), [
              If(
                pli.eq(Const(numCtx - 1, width: pliW)),
                then: [st < Const(sInit, width: 7)],
                orElse: [pli < (pli + Const(1, width: pliW))],
              ),
            ]),
            CaseItem(Const(sInit, width: 7), [st < Const(sPop, width: 7)]),
            CaseItem(Const(sPop, width: 7), [
              If(
                sp.eq(Const(0, width: spW)),
                then: [st < Const(sDone, width: 7)],
                orElse: [
                  nr < stackTop(stR),
                  nc < stackTop(stC),
                  nbs < stackTop(stB),
                  sp < (sp - Const(1, width: spW)),
                  If(
                    stackTop(stB).lt(Const(3, width: 5)),
                    then: [
                      lr[0] < stackTop(stR),
                      lc[0] < stackTop(stC),
                      lbs[0] < stackTop(stB),
                      leafN < Const(1, width: 3),
                      emitIdx < Const(0, width: 3),
                      st < Const(sLeaf, width: 7),
                    ],
                    orElse: [st < Const(sRead, width: 7)],
                  ),
                ],
              ),
            ]),
            CaseItem(Const(sRead, width: 7), [st < Const(sReadCap, width: 7)]),
            CaseItem(Const(sReadCap, width: 7), [
              symCount < (symCount + Const(1, width: 12)),
              emitIdx < Const(0, width: 3),
              Case(sym.getRange(0, 4), [
                CaseItem(
                  Const(0, width: 4),
                  plan([
                    [nr, nc, sub[0]],
                  ]),
                ),
                CaseItem(
                  Const(1, width: 4),
                  plan([
                    [nr, nc, sub[1]],
                    [rPlus(half), nc, sub[1]],
                  ]),
                ),
                CaseItem(
                  Const(2, width: 4),
                  plan([
                    [nr, nc, sub[2]],
                    [nr, cPlus(half), sub[2]],
                  ]),
                ),
                CaseItem(Const(3, width: 4), [
                  ...writeStack(sp, rPlus(half), cPlus(half), sub[3]),
                  ...writeStack(
                    (sp + Const(1, width: spW)).getRange(0, spW),
                    rPlus(half),
                    nc,
                    sub[3],
                  ),
                  ...writeStack(
                    (sp + Const(2, width: spW)).getRange(0, spW),
                    nr,
                    cPlus(half),
                    sub[3],
                  ),
                  ...writeStack(
                    (sp + Const(3, width: spW)).getRange(0, spW),
                    nr,
                    nc,
                    sub[3],
                  ),
                  sp < (sp + Const(4, width: spW)).getRange(0, spW),
                  st < Const(sPop, width: 7),
                ]),
                CaseItem(
                  Const(4, width: 4),
                  plan([
                    [nr, nc, sub[3]],
                    [nr, cPlus(half), sub[3]],
                    [rPlus(half), nc, sub[4]],
                  ]),
                ),
                CaseItem(
                  Const(5, width: 4),
                  plan([
                    [nr, nc, sub[5]],
                    [rPlus(half), nc, sub[3]],
                    [rPlus(half), cPlus(half), sub[3]],
                  ]),
                ),
                CaseItem(
                  Const(6, width: 4),
                  plan([
                    [nr, nc, sub[3]],
                    [rPlus(half), nc, sub[3]],
                    [nr, cPlus(half), sub[6]],
                  ]),
                ),
                CaseItem(
                  Const(7, width: 4),
                  plan([
                    [nr, nc, sub[7]],
                    [nr, cPlus(half), sub[3]],
                    [rPlus(half), cPlus(half), sub[3]],
                  ]),
                ),
                CaseItem(
                  Const(8, width: 4),
                  plan([
                    for (var i = 0; i < 4; i++)
                      [
                        rPlus((quarter * Const(i, width: cW)).getRange(0, cW)),
                        nc,
                        sub[8],
                      ],
                  ]),
                ),
                CaseItem(
                  Const(9, width: 4),
                  plan([
                    for (var i = 0; i < 4; i++)
                      [
                        nr,
                        cPlus((quarter * Const(i, width: cW)).getRange(0, cW)),
                        sub[9],
                      ],
                  ]),
                ),
              ]),
            ]),
            // per-leaf mode info
            CaseItem(Const(sLeaf, width: 7), [
              if (coeffPrefix) ...[
                for (var i = 0; i < bufLen; i++) levels[i] < Const(0, width: 8),
                for (var i = 0; i < leafCoeffN; i++)
                  coeffsRam[i] < Const(0, width: coefW),
                if (txLeaf) ...[
                  for (var i = 0; i < bufLen8; i++)
                    levels8[i] < Const(0, width: 8),
                  // 16x16 leaf levels must also be cleared per-leaf (else a later
                  // leaf reads the previous leaf's stale levels in its 2D coeff
                  // context).
                  if (tx16)
                    for (var i = 0; i < bufLen16; i++)
                      levels16[i] < Const(0, width: 8),
                  if (tx32)
                    for (var i = 0; i < bufLen32; i++)
                      levels32[i] < Const(0, width: 8),
                  for (var i = 0; i < bufLenRect; i++) ...[
                    levels8x4[i] < Const(0, width: 8),
                    levels4x8[i] < Const(0, width: 8),
                  ],
                  for (var i = 0; i < bufLenRectC; i++) ...[
                    levels16x4[i] < Const(0, width: 8),
                    levels4x16[i] < Const(0, width: 8),
                  ],
                  if (tx16)
                    for (var i = 0; i < bufLenRectB; i++) ...[
                      levels16x8[i] < Const(0, width: 8),
                      levels8x16[i] < Const(0, width: 8),
                    ],
                  // fresh leaf: clear the rect + tx-split state so a non-8x8 /
                  // skipped leaf (which never reaches sTxSzCap) starts cleared.
                  leafRect! < Const(0),
                  rectVert! < Const(0),
                  rectKindReg! < Const(0, width: 3),
                  splitActive! < Const(0),
                  subBlk! < Const(0, width: 2),
                  for (var i = 0; i < 4; i++) subTxType[i] < Const(0, width: 4),
                  for (var i = 0; i < 2; i++) ...[
                    subAboveEC[i] < Const(0, width: 8),
                    subLeftEC[i] < Const(0, width: 8),
                  ],
                ],
                culLevelReg < Const(0, width: 7),
                dcSignReg < Const(0, width: 2),
                // fresh leaf: clear the latched luma EC so a SKIPPED leaf (which
                // never reaches the luma-plane-done snapshot) writes a 0 luma
                // neighbour EC, matching libaom (and the pre-chroma behaviour).
                if (chroma) lumaEcReg! < Const(0, width: 8),
              ],
              if (chroma) ...[
                coeffPlane! < Const(0, width: 2),
                uvModeReg < Const(0, width: 4),
                cflIdxReg < Const(0, width: 8),
                cflSignsReg < Const(0, width: 3),
                for (var i = 0; i < chromaN; i++) ...[
                  uCoeffsRam[i] < Const(0, width: coefW),
                  vCoeffsRam[i] < Const(0, width: coefW),
                ],
              ],
              // fresh leaf: clear palette state so a leaf with no palette emits 0.
              if (enablePalette) ...[
                palYSizeReg! < Const(0, width: 4),
                palUVSizeReg! < Const(0, width: 4),
                palMapChkY! < Const(0, width: 32),
                palMapChkUV! < Const(0, width: 32),
                for (var i = 0; i < 8; i++) ...[
                  palColY[i] < Const(0, width: 8),
                  palColU[i] < Const(0, width: 8),
                  palColV[i] < Const(0, width: 8),
                ],
              ],
              st < Const(sSkipDec, width: 7),
            ]),
            CaseItem(Const(sSkipDec, width: 7), [
              st < Const(sSkipCap, width: 7),
            ]),
            CaseItem(Const(sSkipCap, width: 7), [
              skipReg < sym[0],
              symCount < (symCount + Const(1, width: 12)),
              st < Const(sYmDec, width: 7),
            ]),
            CaseItem(Const(sYmDec, width: 7), [st < Const(sYmCap, width: 7)]),
            CaseItem(Const(sYmCap, width: 7), [
              ymReg < sym.getRange(0, 4),
              symCount < (symCount + Const(1, width: 12)),
              st < Const(sAngChk, width: 7),
            ]),
            CaseItem(Const(sAngChk, width: 7), [
              angReg < Const(0, width: 3),
              // reset filter_intra state each leaf (only written when eligible).
              if (enableFilterIntra) ...[
                fiReg! < Const(0),
                fiModeReg! < Const(0, width: 3),
              ],
              If(
                useAngle,
                then: [st < Const(sAngDec, width: 7)],
                orElse: postAngleY(),
              ),
            ]),
            CaseItem(Const(sAngDec, width: 7), [st < Const(sAngCap, width: 7)]),
            CaseItem(Const(sAngCap, width: 7), [
              angReg < sym.getRange(0, 3),
              symCount < (symCount + Const(1, width: 12)),
              ...postAngleY(),
            ]),
            if (enableFilterIntra) ...[
              // use_filter_intra (2-sym). If set, decode filter_intra_mode, else
              // proceed to tx_size. Only reached for DC, <=32x32 leaves.
              CaseItem(Const(sFiDec, width: 7), [st < Const(sFiCap, width: 7)]),
              CaseItem(Const(sFiCap, width: 7), [
                fiReg! < sym[0],
                symCount < (symCount + Const(1, width: 12)),
                If(
                  sym[0],
                  then: [st < Const(sFiModeDec, width: 7)],
                  orElse: enterTokens(),
                ),
              ]),
              CaseItem(Const(sFiModeDec, width: 7), [
                st < Const(sFiModeCap, width: 7),
              ]),
              CaseItem(Const(sFiModeCap, width: 7), [
                fiModeReg! < sym.getRange(0, 3),
                symCount < (symCount + Const(1, width: 12)),
                ...enterTokens(),
              ]),
            ],
            if (enablePalette)
              ...() {
                // indexed write helper.
                List<Conditional> wIdx(List<Logic> arr, Logic idx, Logic val) {
                  Logic fit(int w) =>
                      val.width >= w ? val.getRange(0, w) : val.zeroExtend(w);
                  return [
                    for (var j = 0; j < arr.length; j++)
                      If(
                        idx.eq(Const(j, width: idx.width)),
                        then: [arr[j] < fit(arr[j].width)],
                      ),
                  ];
                }

                // colour merge write to the active plane's colour array.
                List<Conditional> wColor(Logic idx, Logic val) => [
                  If(
                    palPlane!.eq(Const(0, width: 2)),
                    then: wIdx(palColY, idx, val),
                    orElse: wIdx(palColU, idx, val),
                  ),
                ];
                final nNew = (palN! - palIdx!).getRange(0, 4);
                // reusable literal reader.
                final litStates = <CaseItem>[
                  CaseItem(Const(sPalLit, width: 7), [
                    If(
                      palLitCnt!.lt(palLitTarget!),
                      then: [st < Const(sPalLitDec, width: 7)],
                      orElse: [st < palLitRet!],
                    ),
                  ]),
                  CaseItem(Const(sPalLitDec, width: 7), [
                    st < Const(sPalLitCap, width: 7),
                  ]),
                  CaseItem(Const(sPalLitCap, width: 7), [
                    palLitAcc! <
                        ((palLitAcc << Const(1, width: 16)) |
                                sym[0].zeroExtend(16))
                            .getRange(0, 16),
                    palLitCnt < (palLitCnt + Const(1, width: 5)),
                    symCount < (symCount + Const(1, width: 12)),
                    st < Const(sPalLit, width: 7),
                  ]),
                ];
                // Y palette mode
                final modeStates = <CaseItem>[
                  CaseItem(Const(sPalYModeDec, width: 7), [
                    st < Const(sPalYModeCap, width: 7),
                  ]),
                  CaseItem(Const(sPalYModeCap, width: 7), [
                    symCount < (symCount + Const(1, width: 12)),
                    If(
                      sym[0],
                      then: [st < Const(sPalYSizeDec, width: 7)],
                      orElse: [st < Const(sPalUVModeChk, width: 7)],
                    ),
                  ]),
                  CaseItem(Const(sPalYSizeDec, width: 7), [
                    st < Const(sPalYSizeCap, width: 7),
                  ]),
                  CaseItem(Const(sPalYSizeCap, width: 7), [
                    palYSizeReg! < (sym.getRange(0, 4) + Const(2, width: 4)),
                    palN < (sym.getRange(0, 4) + Const(2, width: 4)),
                    palPlane! < Const(0, width: 2),
                    palAi! < Const(0, width: 4),
                    palLi! < Const(0, width: 4),
                    palAn! < palAszY,
                    palLn! < palLszY,
                    palIdx < Const(0, width: 4),
                    palHaveLast! < Const(0),
                    symCount < (symCount + Const(1, width: 12)),
                    st < Const(sPalCacheStep, width: 7),
                  ]),
                  // UV palette mode
                  CaseItem(Const(sPalUVModeChk, width: 7), [
                    if (!chroma)
                      ...enterFilterIntra()
                    else
                      If(
                        uvModeReg.eq(Const(0, width: 4)) & chromaRefV,
                        then: [st < Const(sPalUVModeDec, width: 7)],
                        orElse: enterFilterIntra(),
                      ),
                  ]),
                  if (chroma) ...[
                    CaseItem(Const(sPalUVModeDec, width: 7), [
                      st < Const(sPalUVModeCap, width: 7),
                    ]),
                    CaseItem(Const(sPalUVModeCap, width: 7), [
                      symCount < (symCount + Const(1, width: 12)),
                      If(
                        sym[0],
                        then: [st < Const(sPalUVSizeDec, width: 7)],
                        orElse: enterFilterIntra(),
                      ),
                    ]),
                    CaseItem(Const(sPalUVSizeDec, width: 7), [
                      st < Const(sPalUVSizeCap, width: 7),
                    ]),
                    CaseItem(Const(sPalUVSizeCap, width: 7), [
                      palUVSizeReg! < (sym.getRange(0, 4) + Const(2, width: 4)),
                      palN < (sym.getRange(0, 4) + Const(2, width: 4)),
                      palPlane < Const(1, width: 2),
                      palAi < Const(0, width: 4),
                      palLi < Const(0, width: 4),
                      palAn < palAszUV,
                      palLn < palLszUV,
                      palIdx < Const(0, width: 4),
                      palHaveLast < Const(0),
                      symCount < (symCount + Const(1, width: 12)),
                      st < Const(sPalCacheStep, width: 7),
                    ]),
                  ],
                ];
                // colour cache-hit merge + new-colour read + merge
                final colorStates = <CaseItem>[
                  CaseItem(Const(sPalCacheStep, width: 7), [
                    If(
                      palMoreCache & palIdx.lt(palN),
                      then: [
                        // advance the merge pointers (always).
                        palAi < (palAi + palAdvA.zeroExtend(4)).getRange(0, 4),
                        palLi < (palLi + palAdvL.zeroExtend(4)).getRange(0, 4),
                        palAn < (palAn - palAdvA.zeroExtend(4)).getRange(0, 4),
                        palLn < (palLn - palAdvL.zeroExtend(4)).getRange(0, 4),
                        palCacheVal! < palNextVal,
                        If(
                          palHaveLast & palNextVal.eq(palLastCache!),
                          then: [
                            // duplicate cache entry: no hit bool, keep looping.
                            st < Const(sPalCacheStep, width: 7),
                          ],
                          orElse: [
                            palHaveLast < Const(1),
                            palLastCache < palNextVal,
                            ...startLit(1, null, sPalCacheCap),
                          ],
                        ),
                      ],
                      orElse: [st < Const(sPalNewInit, width: 7)],
                    ),
                  ]),
                  CaseItem(Const(sPalCacheCap, width: 7), [
                    If(
                      palLitAcc[0],
                      then: [
                        ...wIdx(palCached, palIdx, palLastCache),
                        palIdx < (palIdx + Const(1, width: 4)),
                      ],
                    ),
                    st < Const(sPalCacheStep, width: 7),
                  ]),
                  CaseItem(Const(sPalNewInit, width: 7), [
                    nNewReg! < nNew,
                    If(
                      palIdx.gte(palN),
                      then: [
                        // all colours came from the cache: merge (copies cached).
                        pci! < Const(0, width: 4),
                        pti! < Const(0, width: 4),
                        palMi! < Const(0, width: 4),
                        st < Const(sPalMerge, width: 7),
                      ],
                      orElse: [
                        palMi < Const(0, width: 4),
                        ...startLit(palBd, null, sPalNewFirstCap),
                      ],
                    ),
                  ]),
                  CaseItem(Const(sPalNewFirstCap, width: 7), [
                    ...wIdx(palNew, Const(0, width: 4), palLitAcc),
                    palPrev! < palLitAcc.getRange(0, 9),
                    palMi < Const(1, width: 4),
                    If(
                      nNewReg.eq(Const(1, width: 4)),
                      then: [
                        pci < Const(0, width: 4),
                        pti < Const(0, width: 4),
                        palMi < Const(0, width: 4),
                        st < Const(sPalMerge, width: 7),
                      ],
                      orElse: [...startLit(2, null, sPalBits2Cap)],
                    ),
                  ]),
                  CaseItem(Const(sPalBits2Cap, width: 7), [
                    // Y/U minBits = bd-3. bits = minBits + read(2).
                    palBits! <
                        (Const(palBd - 3, width: 5) + palLitAcc.getRange(0, 5))
                            .getRange(0, 5),
                    // range: Y = (1<<bd)-first-1, U = (1<<bd)-first.
                    palRange! <
                        mux(
                          palPlane.eq(Const(1, width: 2)),
                          (Const(1 << palBd, width: 13) -
                                  selList(
                                    palNew,
                                    Const(0, width: 4),
                                  ).zeroExtend(13))
                              .getRange(0, 13),
                          (Const((1 << palBd) - 1, width: 13) -
                                  selList(
                                    palNew,
                                    Const(0, width: 4),
                                  ).zeroExtend(13))
                              .getRange(0, 13),
                        ),
                    st < Const(sPalDeltaLoop, width: 7),
                  ]),
                  CaseItem(Const(sPalDeltaLoop, width: 7), [
                    If(
                      palMi.lt(nNewReg),
                      then: startLit(null, palBits, sPalDeltaCap),
                      orElse: [
                        pci < Const(0, width: 4),
                        pti < Const(0, width: 4),
                        palMi < Const(0, width: 4),
                        st < Const(sPalMerge, width: 7),
                      ],
                    ),
                  ]),
                  CaseItem(Const(sPalDeltaCap, width: 7), () {
                    // Y delta = read + 1, U delta = read.
                    final delta = mux(
                      palPlane.eq(Const(1, width: 2)),
                      palLitAcc.getRange(0, 12),
                      (palLitAcc.getRange(0, 12) + Const(1, width: 12))
                          .getRange(0, 12),
                    );
                    final sum = (palPrev.zeroExtend(13) + delta.zeroExtend(13))
                        .getRange(0, 13);
                    final clamped = mux(
                      sum.gt(Const((1 << palBd) - 1, width: 13)),
                      Const((1 << palBd) - 1, width: 13),
                      sum,
                    );
                    final diff = (clamped - palPrev.zeroExtend(13)).getRange(
                      0,
                      13,
                    );
                    final newRange = (palRange - diff).getRange(0, 13);
                    final cl = palCeilLog2(newRange);
                    return <Conditional>[
                      ...wColor(palMi, clamped.getRange(0, 8)),
                      ...wIdx(palNew, palMi, clamped.getRange(0, 8)),
                      palPrev < clamped.getRange(0, 9),
                      palRange < newRange,
                      If(cl.lt(palBits), then: [palBits < cl]),
                      palMi < (palMi + Const(1, width: 4)),
                      st < Const(sPalDeltaLoop, width: 7),
                    ];
                  }()),
                  CaseItem(Const(sPalMerge, width: 7), [
                    If(
                      palMi.lt(palN),
                      then: () {
                        final takeCached =
                            pci.lt(palIdx) &
                            (pti.gte(nNewReg) |
                                selList(
                                  palCached,
                                  pci,
                                ).lte(selList(palNew, pti)));
                        final val = mux(
                          takeCached,
                          selList(palCached, pci),
                          selList(palNew, pti),
                        );
                        return <Conditional>[
                          ...wColor(palMi, val),
                          If(
                            takeCached,
                            then: [pci < (pci + Const(1, width: 4))],
                            orElse: [pti < (pti + Const(1, width: 4))],
                          ),
                          palMi < (palMi + Const(1, width: 4)),
                          st < Const(sPalMerge, width: 7),
                        ];
                      }(),
                      orElse: [st < Const(sPalColDone, width: 7)],
                    ),
                  ]),
                  CaseItem(Const(sPalColDone, width: 7), [
                    If(
                      palPlane.eq(Const(0, width: 2)),
                      then: [st < Const(sPalUVModeChk, width: 7)],
                      orElse: [
                        // U done -> read the V channel (mode bool first).
                        ...startLit(1, null, sPalVModeCap),
                      ],
                    ),
                  ]),
                ];
                // V channel (chroma only)
                final vStates = chroma
                    ? <CaseItem>[
                        CaseItem(Const(sPalVModeCap, width: 7), [
                          If(
                            palLitAcc[0],
                            then: [...startLit(2, null, sPalVBits2Cap)],
                            orElse: [
                              palMi < Const(0, width: 4),
                              st < Const(sPalVDirLoop, width: 7),
                            ],
                          ),
                        ]),
                        CaseItem(Const(sPalVBits2Cap, width: 7), [
                          palBits <
                              (Const(palBd - 4, width: 5) +
                                      palLitAcc.getRange(0, 5))
                                  .getRange(0, 5),
                          ...startLit(palBd, null, sPalVFirstCap),
                        ]),
                        CaseItem(Const(sPalVFirstCap, width: 7), [
                          ...wIdx(palColV, Const(0, width: 4), palLitAcc),
                          palPrev < palLitAcc.getRange(0, 9),
                          palMi < Const(1, width: 4),
                          st < Const(sPalVDeltaLoop, width: 7),
                        ]),
                        CaseItem(Const(sPalVDeltaLoop, width: 7), [
                          If(
                            palMi.lt(palN),
                            then: startLit(null, palBits, sPalVDeltaCap),
                            orElse: enterFilterIntra(),
                          ),
                        ]),
                        CaseItem(Const(sPalVDeltaCap, width: 7), [
                          If(
                            palLitAcc.getRange(0, 12).eq(Const(0, width: 12)),
                            then: [
                              // delta 0: colour unchanged.
                              ...wIdx(palColV, palMi, palPrev.getRange(0, 8)),
                              palMi < (palMi + Const(1, width: 4)),
                              st < Const(sPalVDeltaLoop, width: 7),
                            ],
                            orElse: [
                              palRange < palLitAcc.getRange(0, 13), // |delta|
                              ...startLit(1, null, sPalVSignCap),
                            ],
                          ),
                        ]),
                        CaseItem(Const(sPalVSignCap, width: 7), () {
                          final maxV = Const(1 << palBd, width: 13);
                          final mag = palRange;
                          final neg = palLitAcc[0];
                          // val = prev + (neg ? -mag : mag), wrapped mod (1<<bd).
                          final rawPos = (palPrev.zeroExtend(13) + mag)
                              .getRange(0, 13);
                          final rawNeg = (palPrev.zeroExtend(13) - mag)
                              .getRange(0, 13);
                          final wrapPos = mux(
                            rawPos.gte(maxV),
                            (rawPos - maxV).getRange(0, 13),
                            rawPos,
                          );
                          final wrapNeg = mux(
                            rawNeg[12],
                            (rawNeg + maxV).getRange(0, 13),
                            rawNeg,
                          );
                          final val = mux(neg, wrapNeg, wrapPos);
                          return <Conditional>[
                            ...wIdx(palColV, palMi, val.getRange(0, 8)),
                            palPrev < val.getRange(0, 9),
                            palMi < (palMi + Const(1, width: 4)),
                            st < Const(sPalVDeltaLoop, width: 7),
                          ];
                        }()),
                        CaseItem(Const(sPalVDirLoop, width: 7), [
                          If(
                            palMi.lt(palN),
                            then: startLit(palBd, null, sPalVDirCap),
                            orElse: enterFilterIntra(),
                          ),
                        ]),
                        CaseItem(Const(sPalVDirCap, width: 7), [
                          ...wIdx(palColV, palMi, palLitAcc),
                          palMi < (palMi + Const(1, width: 4)),
                          st < Const(sPalVDirLoop, width: 7),
                        ]),
                      ]
                    : <CaseItem>[];
                // colour-index-map tokens
                // block pixel dims from the leaf size enum.
                final blkWpx = (romSel(_miWide, eb, 8) << 2).getRange(0, 7);
                final blkHpx = (romSel(_miHigh, eb, 8) << 2).getRange(0, 7);
                // plane geometry (4:2:0, in-scope block sizes never hit the sub-8x8
                // chroma padding, so planeW==cols and planeH==rows).
                final pBw = mux(
                  palTokPlane!.eq(Const(0, width: 1)),
                  blkWpx,
                  (blkWpx >> 1).getRange(0, 7),
                );
                final pBh = mux(
                  palTokPlane.eq(Const(0, width: 1)),
                  blkHpx,
                  (blkHpx >> 1).getRange(0, 7),
                );
                // NS first-index params from palN: l = bitLen(n-1), m = (1<<l)-n.
                final nsL = () {
                  final m = (palN - Const(1, width: 4)).getRange(0, 4);
                  Logic bl = Const(0, width: 5);
                  for (var b = 1; b <= 4; b++) {
                    bl = mux(
                      m.gte(Const(1 << (b - 1), width: 4)),
                      Const(b, width: 5),
                      bl,
                    );
                  }
                  return bl;
                }();
                final nsM =
                    (((Const(1, width: 9) << nsL.getRange(0, 4)) -
                            palN.zeroExtend(9)))
                        .getRange(0, 9);
                final totalDiag =
                    (palRows!.zeroExtend(6) +
                            palCols!.zeroExtend(6) -
                            Const(1, width: 6))
                        .getRange(0, 6);
                final rrTok = (palTokI!.zeroExtend(6) - palTokJ!.zeroExtend(6))
                    .getRange(0, 6);
                final ccTok = palTokJ.zeroExtend(6);
                final mapIdxTok = ((rrTok * palPlaneW!.zeroExtend(6)) + ccTok)
                    .getRange(0, 6);
                final jlo = () {
                  final v =
                      (palTokI.zeroExtend(6) +
                              Const(1, width: 6) -
                              palRows.zeroExtend(6))
                          .getRange(0, 6);
                  return mux(v[5], Const(0, width: 6), v); // max(0, i-(rows-1))
                }();
                final jhiNext = () {
                  final ni = (palTokI + Const(1, width: 5)).getRange(0, 5);
                  final colsM1 = (palCols - Const(1, width: 5)).getRange(0, 5);
                  return mux(ni.lt(colsM1), ni, colsM1); // min(i+1, cols-1)
                }();
                // raster-order checksum fold of the current plane's map.
                Logic mapChk(int maxLen) {
                  final len = (palPlaneW.zeroExtend(7) * pBh.zeroExtend(7))
                      .getRange(0, 7);
                  Logic h = Const(0, width: 32);
                  for (var i = 0; i < maxLen; i++) {
                    final nh =
                        ((h * Const(31, width: 32)) + palMap[i].zeroExtend(32))
                            .getRange(0, 32);
                    h = mux(Const(i, width: 7).lt(len), nh, h);
                  }
                  return h;
                }

                final tokStates = <CaseItem>[
                  CaseItem(Const(sPalTokInit, width: 7), [
                    palN <
                        mux(
                          palTokPlane.eq(Const(0, width: 1)),
                          palYSizeReg,
                          palUVSizeReg!,
                        ),
                    palPlaneW < pBw.getRange(0, 5),
                    palCols < pBw.getRange(0, 5),
                    palRows < pBh.getRange(0, 5),
                    st < Const(sPalNSInit, width: 7),
                  ]),
                  CaseItem(Const(sPalNSInit, width: 7), [
                    palRange < nsM.zeroExtend(13), // stash m
                    ...startLit(
                      null,
                      (nsL - Const(1, width: 5)).getRange(0, 5),
                      sPalNSCap,
                    ),
                  ]),
                  CaseItem(Const(sPalNSCap, width: 7), [
                    If(
                      palLitAcc.getRange(0, 9).lt(palRange.getRange(0, 9)),
                      then: [
                        // v < m: index = v.
                        ...wIdx(
                          palMap,
                          Const(0, width: 6),
                          palLitAcc.getRange(0, 4),
                        ),
                        palTokI < Const(1, width: 5),
                        palTokJ <
                            () {
                              final colsM1 = (palCols - Const(1, width: 5))
                                  .getRange(0, 5);
                              return mux(
                                Const(1, width: 5).lt(colsM1),
                                Const(1, width: 5),
                                colsM1,
                              );
                            }(),
                        st < Const(sPalTokStep, width: 7),
                      ],
                      orElse: [
                        palPrev < palLitAcc.getRange(0, 9), // stash v
                        ...startLit(1, null, sPalNSHiCap),
                      ],
                    ),
                  ]),
                  CaseItem(Const(sPalNSHiCap, width: 7), [
                    // index = (v<<1) - m + bit.
                    ...wIdx(
                      palMap,
                      Const(0, width: 6),
                      (((palPrev.getRange(0, 9) << Const(1, width: 9)) -
                                  palRange.getRange(0, 9)) +
                              palLitAcc.getRange(0, 9))
                          .getRange(0, 4),
                    ),
                    palTokI < Const(1, width: 5),
                    palTokJ <
                        () {
                          final colsM1 = (palCols - Const(1, width: 5))
                              .getRange(0, 5);
                          return mux(
                            Const(1, width: 5).lt(colsM1),
                            Const(1, width: 5),
                            colsM1,
                          );
                        }(),
                    st < Const(sPalTokStep, width: 7),
                  ]),
                  CaseItem(Const(sPalTokStep, width: 7), [
                    If(
                      palTokI.zeroExtend(6).lt(totalDiag),
                      then: [st < Const(sPalTokDec, width: 7)],
                      orElse: [
                        // plane tokens done: fold the map checksum, then next plane.
                        If(
                          palTokPlane.eq(Const(0, width: 1)),
                          then: [
                            palMapChkY! < mapChk(64),
                            if (chroma)
                              If(
                                palUVSizeReg.gt(Const(0, width: 4)),
                                then: [
                                  palTokPlane < Const(1, width: 1),
                                  st < Const(sPalTokInit, width: 7),
                                ],
                                orElse: afterMode(),
                              )
                            else
                              ...afterMode(),
                          ],
                          orElse: [palMapChkUV! < mapChk(64), ...afterMode()],
                        ),
                      ],
                    ),
                  ]),
                  CaseItem(Const(sPalTokDec, width: 7), [
                    st < Const(sPalTokCap, width: 7),
                  ]),
                  CaseItem(Const(sPalTokCap, width: 7), [
                    ...wIdx(palMap, mapIdxTok, palTokOrderCi),
                    symCount < (symCount + Const(1, width: 12)),
                    If(
                      palTokJ.zeroExtend(6).gt(jlo),
                      then: [
                        palTokJ < (palTokJ - Const(1, width: 5)),
                        st < Const(sPalTokStep, width: 7),
                      ],
                      orElse: [
                        palTokI < (palTokI + Const(1, width: 5)),
                        palTokJ < jhiNext.getRange(0, 5),
                        st < Const(sPalTokStep, width: 7),
                      ],
                    ),
                  ]),
                ];
                return [
                  ...litStates,
                  ...modeStates,
                  ...colorStates,
                  ...vStates,
                  ...tokStates,
                ];
              }(),
            if (chroma) ...[
              // uv_mode (14-sym). uv_mode == 13 (UV_CFL_PRED) reads cfl alphas.
              CaseItem(Const(sUvDec, width: 7), [st < Const(sUvCap, width: 7)]),
              CaseItem(Const(sUvCap, width: 7), [
                uvModeReg < sym.getRange(0, 4),
                symCount < (symCount + Const(1, width: 12)),
                If(
                  sym.getRange(0, 4).eq(Const(13, width: 4)),
                  then: [st < Const(sCflSignDec, width: 7)],
                  orElse: [st < Const(sAngUvChk, width: 7)],
                ),
              ]),
              CaseItem(Const(sCflSignDec, width: 7), [
                st < Const(sCflSignCap, width: 7),
              ]),
              CaseItem(Const(sCflSignCap, width: 7), [
                cflSignsReg < sym.getRange(0, 3),
                cflIdxReg < Const(0, width: 8),
                symCount < (symCount + Const(1, width: 12)),
                // signU != 0  <=>  js >= 2, signV != 0  <=>  js not in {2,5}.
                If(
                  sym.getRange(0, 3).gte(Const(2, width: 3)),
                  then: [st < Const(sCflULoad, width: 7)],
                  orElse: [
                    If(
                      sym.getRange(0, 3).eq(Const(2, width: 3)) |
                          sym.getRange(0, 3).eq(Const(5, width: 3)),
                      then: [st < Const(sAngUvChk, width: 7)],
                      orElse: [st < Const(sCflVLoad, width: 7)],
                    ),
                  ],
                ),
              ]),
              CaseItem(Const(sCflULoad, width: 7), [
                st < Const(sCflUDec, width: 7),
              ]),
              CaseItem(Const(sCflUDec, width: 7), [
                st < Const(sCflUCap, width: 7),
              ]),
              CaseItem(Const(sCflUCap, width: 7), [
                // idx = cfl_alpha_u << 4.
                cflIdxReg <
                    (sym.getRange(0, 4).zeroExtend(8) << Const(4, width: 4))
                        .getRange(0, 8),
                symCount < (symCount + Const(1, width: 12)),
                If(
                  cflSignVnz!,
                  then: [st < Const(sCflVLoad, width: 7)],
                  orElse: [st < Const(sAngUvChk, width: 7)],
                ),
              ]),
              CaseItem(Const(sCflVLoad, width: 7), [
                st < Const(sCflVDec, width: 7),
              ]),
              CaseItem(Const(sCflVDec, width: 7), [
                st < Const(sCflVCap, width: 7),
              ]),
              CaseItem(Const(sCflVCap, width: 7), [
                cflIdxReg <
                    (cflIdxReg + sym.getRange(0, 4).zeroExtend(8)).getRange(
                      0,
                      8,
                    ),
                symCount < (symCount + Const(1, width: 12)),
                st < Const(sAngUvChk, width: 7),
              ]),
              // angle_delta_uv: directional uv intra mode (getUvMode(uv) in 1..8)
              // AND bSize >= 8x8 (av1UseAngleDelta). The 8x8 NONE leaf (eb=3)
              // reads it, a SPLIT 4x4 chromaRef leaf (eb=0) does NOT, matching
              // av1UseAngleDelta(BLOCK_4X4) == false. No checksum impact.
              CaseItem(Const(sAngUvChk, width: 7), [
                angUvReg < Const(0, width: 3),
                ...() {
                  final uvIntra = romSel(_uv2y, uvModeReg, 4);
                  final uvDir =
                      uvIntra.gte(Const(1, width: 4)) &
                      uvIntra.lte(Const(8, width: 4));
                  final useUvAngle = eb.gte(Const(3, width: 5)) & uvDir;
                  return <Conditional>[
                    If(
                      useUvAngle,
                      then: [st < Const(sAngUvDec, width: 7)],
                      orElse: enterPalette(),
                    ),
                  ];
                }(),
              ]),
              CaseItem(Const(sAngUvDec, width: 7), [
                st < Const(sAngUvCap, width: 7),
              ]),
              CaseItem(Const(sAngUvCap, width: 7), [
                angUvReg < sym.getRange(0, 3),
                symCount < (symCount + Const(1, width: 12)),
                ...enterPalette(),
              ]),
            ],
            if (txLeaf) ...[
              // tx_size depth (cat0, 2 syms): depth 0 -> TX_8X8 (one 64-coeff txb,
              // leafTx=1), depth 1 -> the four-TX_4X4 tx-split sweep (splitActive,
              // leafTx=0, see sSplitNext + the splitTxbSkipCtx/splitDcSignCtx ctx).
              CaseItem(Const(sTxSzDec, width: 7), [
                st < Const(sTxSzCap, width: 7),
              ]),
              CaseItem(Const(sTxSzCap, width: 7), () {
                // Rect leaf: depth 0 keeps the rect geometry. 8x8 leaf: depth 0 ->
                // TX_8X8 (leafTx=1), depth 1 -> the four-TX_4X4 sweep.
                final rect8 = If(
                  leafRect!,
                  then: [
                    leafTx < Const(0),
                    txDepthReg! < sym[0].zeroExtend(2),
                    splitActive! < Const(0),
                    subBlk! < Const(0, width: 2),
                    st < Const(sTxbDec, width: 7),
                  ],
                  orElse: [
                    leafTx < ~sym[0],
                    txDepthReg < sym[0].zeroExtend(2),
                    splitActive < sym[0],
                    subBlk < Const(0, width: 2),
                    for (var i = 0; i < 2; i++) ...[
                      subAboveEC[i] < Const(0, width: 8),
                      subLeftEC[i] < Const(0, width: 8),
                    ],
                    st < Const(sTxbDec, width: 7),
                  ],
                );
                // 16x16 leaf: depth 0 -> TX_16X16 (leafTx16Reg=1), depth 1 -> the
                // four-TX_8X8 sweep (split16Active, leafTx=1 for the TX_8X8 coeff
                // geometry). Depth 2 (sixteen TX_4X4) out of scope for the DCT-only
                // streams. rect8 is the 8x8/rect path.
                List<Conditional> sz16OrRect() => tx16
                    ? [
                        If(
                          leafIs16,
                          then: () {
                            final d0 = sym
                                .getRange(0, 2)
                                .eq(Const(0, width: 2));
                            final d1 = sym
                                .getRange(0, 2)
                                .eq(Const(1, width: 2));
                            return <Conditional>[
                              leafTx16Reg! < d0,
                              leafTx <
                                  d1, // TX_8X8 geometry for the depth-1 sweep
                              split16Active! < d1,
                              leaf16SplitReg! < d1,
                              txDepthReg < sym.getRange(0, 2),
                              splitActive < Const(0),
                              subBlk < Const(0, width: 2),
                              // clear the TX_8X8 level buffer + accumulators for the
                              // first sub-block of a depth-1 sweep.
                              for (var i = 0; i < bufLen8; i++)
                                levels8[i] < Const(0, width: 8),
                              culLevelReg < Const(0, width: 7),
                              dcSignReg < Const(0, width: 2),
                              st < Const(sTxbDec, width: 7),
                            ];
                          }(),
                          orElse: [rect8],
                        ),
                      ]
                    : [rect8];
                return [
                  symCount < (symCount + Const(1, width: 12)),
                  // 32x32 / 64x64 leaf: depth 0 -> TX_32X32/64X64 (leafTx32Reg=1).
                  // Deeper depths out of scope. Wins over the 16x16/rect path.
                  if (tx32)
                    If(
                      leafIs32 | leafIs64,
                      then: [
                        leafTx32Reg! <
                            sym.getRange(0, 2).eq(Const(0, width: 2)),
                        leafTx < Const(0),
                        txDepthReg < sym.getRange(0, 2),
                        splitActive < Const(0),
                        subBlk < Const(0, width: 2),
                        st < Const(sTxbDec, width: 7),
                      ],
                      orElse: sz16OrRect(),
                    )
                  else
                    ...sz16OrRect(),
                ];
              }()),
            ],
            if (coeffPrefix) ...[
              CaseItem(Const(sTxbDec, width: 7), [
                st < Const(sTxbCap, width: 7),
              ]),
              CaseItem(Const(sTxbCap, width: 7), [
                allZeroReg < sym[0],
                symCount < (symCount + Const(1, width: 12)),
                If(
                  sym[0],
                  then: [
                    txTypeReg < Const(0, width: 4),
                    // all-zero split sub-block: no ext-tx read, so its per-sub-block
                    // tx_type is 0 (matches the recon golden's all-zero default).
                    if (txLeaf)
                      If(
                        splitActive! | (tx16 ? split16Active! : Const(0)),
                        then: [
                          for (var s = 0; s < 4; s++)
                            If(
                              subBlk!.eq(Const(s, width: 2)),
                              then: [subTxType[s] < Const(0, width: 4)],
                            ),
                        ],
                      ),
                    eobReg < Const(0, width: 11),
                    coeffDoneNext(),
                  ],
                  orElse: [
                    // A TX_32X32 / TX_64X64 luma leaf uses EXT_TX_SET_DCTONLY: no
                    // ext-tx symbol, txType=DCT_DCT, TX_CLASS_2D -> skip straight to
                    // eob. (Chroma also derives its tx type without an ext-tx read.)
                    if (tx32)
                      If(
                        leafTx32Reg!,
                        then: [
                          txTypeReg < Const(0, width: 4),
                          classReg < Const(0, width: 2),
                          st < Const(sEobPt, width: 7),
                        ],
                        orElse: [
                          if (chroma)
                            If(
                              isChroma,
                              then: [
                                txTypeReg < Const(0, width: 4),
                                classReg < Const(0, width: 2),
                                st < Const(sEobPt, width: 7),
                              ],
                              orElse: [st < Const(sExtTxDec, width: 7)],
                            )
                          else
                            st < Const(sExtTxDec, width: 7),
                        ],
                      )
                    else if (chroma)
                      If(
                        isChroma,
                        then: [
                          txTypeReg < Const(0, width: 4),
                          classReg < Const(0, width: 2),
                          st < Const(sEobPt, width: 7),
                        ],
                        orElse: [st < Const(sExtTxDec, width: 7)],
                      )
                    else
                      st < Const(sExtTxDec, width: 7),
                  ],
                ),
              ]),
              CaseItem(Const(sExtTxDec, width: 7), [
                st < Const(sExtTxCap, width: 7),
              ]),
              CaseItem(Const(sExtTxCap, width: 7), [
                txTypeReg <
                    () {
                      Logic v8 = Const(_extTxInv.last, width: 4);
                      for (var i = _extTxInv.length - 2; i >= 0; i--) {
                        v8 = mux(
                          sym.getRange(0, 4).eq(Const(i, width: 4)),
                          Const(_extTxInv[i], width: 4),
                          v8,
                        );
                      }
                      if (!tx16) return v8;
                      Logic v16 = Const(_extTxInv16.last, width: 4);
                      for (var i = _extTxInv16.length - 2; i >= 0; i--) {
                        v16 = mux(
                          sym.getRange(0, 4).eq(Const(i, width: 4)),
                          Const(_extTxInv16[i], width: 4),
                          v16,
                        );
                      }
                      return mux(leafTx16Reg!, v16, v8);
                    }(),
                // depth-1 (split) path: snapshot THIS sub-block's ext-tx type into
                // subTxType[subBlk] (raster order) so recon can transform each 4x4
                // sub-block with its own tx_type. Guarded by splitActive so the
                // non-split (TX_8X8 / 4x4-leaf / chroma) paths leave it untouched.
                if (txLeaf)
                  If(
                    splitActive! | (tx16 ? split16Active! : Const(0)),
                    then: [
                      for (var s = 0; s < 4; s++)
                        If(
                          subBlk!.eq(Const(s, width: 2)),
                          then: [
                            subTxType[s] <
                                () {
                                  Logic v = Const(_extTxInv.last, width: 4);
                                  for (
                                    var i = _extTxInv.length - 2;
                                    i >= 0;
                                    i--
                                  ) {
                                    v = mux(
                                      sym.getRange(0, 4).eq(Const(i, width: 4)),
                                      Const(_extTxInv[i], width: 4),
                                      v,
                                    );
                                  }
                                  return v;
                                }(),
                          ],
                        ),
                    ],
                  ),
                // sExtTxCap runs only for the LUMA plane (chroma derives its tx
                // type without an ext-tx read). Snapshot the luma ext-tx type into
                // the per-leaf luma-tx buffer before the chroma decode clobbers
                // txTypeReg, so leaf_luma_txtypes survives to the leaf emit.
                if (chroma)
                  for (var j = 0; j < maxLeafOut; j++)
                    If(
                      leafCount.eq(Const(j, width: 12)),
                      then: [
                        lumaTxOut[j] <
                            () {
                              // MUST mirror txTypeReg: a tx16 (16x16) leaf maps the
                              // ext-tx symbol via _extTxInv16, not the 4x4/8x8 _extTxInv.
                              Logic v = Const(_extTxInv.last, width: 4);
                              for (var i = _extTxInv.length - 2; i >= 0; i--) {
                                v = mux(
                                  sym.getRange(0, 4).eq(Const(i, width: 4)),
                                  Const(_extTxInv[i], width: 4),
                                  v,
                                );
                              }
                              if (!tx16) return v;
                              Logic v16 = Const(_extTxInv16.last, width: 4);
                              for (
                                var i = _extTxInv16.length - 2;
                                i >= 0;
                                i--
                              ) {
                                v16 = mux(
                                  sym.getRange(0, 4).eq(Const(i, width: 4)),
                                  Const(_extTxInv16[i], width: 4),
                                  v16,
                                );
                              }
                              return mux(leafTx16Reg!, v16, v);
                            }(),
                      ],
                    ),
                classReg <
                    () {
                      final c8 = mux(
                        sym.getRange(0, 4).eq(Const(2, width: 4)),
                        Const(2, width: 2),
                        mux<Logic>(
                          sym.getRange(0, 4).eq(Const(3, width: 4)),
                          Const(1, width: 2),
                          Const(0, width: 2),
                        ),
                      );
                      return tx16
                          ? mux(leafTx16Reg!, Const(0, width: 2), c8)
                          : c8;
                    }(),
                symCount < (symCount + Const(1, width: 12)),
                st < Const(sEobPt, width: 7),
              ]),
              // eob decode (eob_pt + eob_extra)
              CaseItem(Const(sEobPt, width: 7), [
                st < Const(sEobPtCap, width: 7),
              ]),
              CaseItem(Const(sEobPtCap, width: 7), [
                eobPtReg <
                    (sym.zeroExtend(4) + Const(1, width: 4)).getRange(0, 4),
                symCount < (symCount + Const(1, width: 12)),
                st < Const(sExtra, width: 7),
              ]),
              CaseItem(Const(sExtra, width: 7), [
                offBitsReg < offBits,
                eobExtraReg < Const(0, width: 11),
                If(
                  offBits.eq(Const(0, width: 4)),
                  then: [
                    bypIdxReg < Const(0, width: 4),
                    st < Const(sByp, width: 7),
                  ],
                  orElse: [st < Const(sExtraCap, width: 7)],
                ),
              ]),
              CaseItem(Const(sExtraCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
                If(
                  sym[0],
                  then: [
                    eobExtraReg <
                        (Const(1, width: 11) <<
                                (offBitsReg - Const(1, width: 4)).getRange(
                                  0,
                                  4,
                                ))
                            .getRange(0, 11),
                  ],
                ),
                bypIdxReg < Const(1, width: 4),
                st < Const(sByp, width: 7),
              ]),
              CaseItem(Const(sByp, width: 7), [
                If(
                  bypIdxReg.gte(offBitsReg),
                  then: [
                    // eob settled, start the base reverse-scan at cIdx = eob-1.
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
                    brIdxReg < Const(0, width: 3),
                    st < Const(sBaseDec, width: 7),
                  ],
                  orElse: [st < Const(sBypDec, width: 7)],
                ),
              ]),
              CaseItem(Const(sBypDec, width: 7), [
                st < Const(sBypCap, width: 7),
              ]),
              CaseItem(Const(sBypCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
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
                st < Const(sByp, width: 7),
              ]),
              // base/br reverse-scan
              CaseItem(Const(sBaseDec, width: 7), [
                st < Const(sBaseCap, width: 7),
              ]),
              CaseItem(Const(sBaseCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
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
                    st < Const(sBrDec, width: 7),
                  ],
                  orElse: [
                    ...writeLevelAt(
                      mux(
                        isEobMinus1,
                        sym.zeroExtend(8) + Const(1, width: 8),
                        sym.zeroExtend(8),
                      ),
                    ),
                    st < Const(sNext, width: 7),
                  ],
                ),
              ]),
              CaseItem(Const(sBrDec, width: 7), [st < Const(sBrCap, width: 7)]),
              CaseItem(Const(sBrCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
                levelReg < (levelReg + sym.zeroExtend(8)).getRange(0, 8),
                If(
                  sym.lt(Const(3, width: sym.width)) |
                      brIdxReg.eq(Const(3, width: 3)),
                  then: [
                    ...writeLevelAt(
                      (levelReg + sym.zeroExtend(8)).getRange(0, 8),
                    ),
                    st < Const(sNext, width: 7),
                  ],
                  orElse: [
                    brIdxReg < (brIdxReg + Const(1, width: 3)),
                    st < Const(sBrDec, width: 7),
                  ],
                ),
              ]),
              CaseItem(Const(sNext, width: 7), [
                If(
                  cIdx.eq(Const(0, width: cidxW)),
                  then: [
                    // base levels done, start phase B forward from cIdx = 0.
                    cIdx < Const(0, width: cidxW),
                    culLevelReg < Const(0, width: 7),
                    dcSignReg < Const(0, width: 2),
                    st < Const(sPbCheck, width: 7),
                  ],
                  orElse: [
                    cIdx < (cIdx - Const(1, width: cidxW)),
                    st < Const(sBaseDec, width: 7),
                  ],
                ),
              ]),
              // phase B: signs + golomb + dequant + placement
              CaseItem(Const(sPbCheck, width: 7), [
                ...() {
                  // chroma planes are TX_4X4 (use the 4x4 levels even though the
                  // luma leafTx flag is still set for the 8x8 luma block).
                  final use8 = chroma
                      ? (leafTx & ~isChroma)
                      : (txLeaf ? leafTx : null);
                  final cur0 = use8 == null
                      ? pbLevelCur
                      : mux(use8, pbLevelCur8!, pbLevelCur);
                  // rect leaf overrides to the rect current level for its LUMA
                  // plane, the chroma (U/V) plane is an isolated TX_4X4 block so
                  // isChroma must win over leafRect (pbLevelCur = 4x4 levels).
                  final lumaRectCur = txLeaf
                      ? mux(leafRect!, pbLevelCur32!, cur0)
                      : cur0;
                  final lumaSizedCur16 = tx16
                      ? mux(leafTx16Reg!, pbLevelCur16!, lumaRectCur)
                      : lumaRectCur;
                  final lumaSizedCur = tx32
                      ? mux(leafTx32Reg!, pbLevelCur32b!, lumaSizedCur16)
                      : lumaSizedCur16;
                  final cur = chroma
                      ? mux(
                          isChroma,
                          chroma8
                              ? pbLevelCur8!
                              : chroma16
                              ? pbLevelCur16!
                              : chroma422Leaf
                              ? pbLevelCurC422!
                              : pbLevelCur,
                          lumaSizedCur,
                        )
                      : lumaSizedCur;
                  return <Conditional>[
                    pbLevelReg < cur.zeroExtend(21),
                    If(
                      cur.eq(Const(0, width: 8)),
                      then: [
                        st < Const(sPbNext, width: 7), // zero coeff
                      ],
                      orElse: [
                        If(
                          isC0pb,
                          then: [st < Const(sPbSignDec, width: 7)],
                          orElse: [st < Const(sPbSignLoad, width: 7)],
                        ),
                      ],
                    ),
                  ];
                }(),
              ]),
              CaseItem(Const(sPbSignLoad, width: 7), [
                st < Const(sPbSignDec, width: 7),
              ]),
              CaseItem(Const(sPbSignDec, width: 7), [
                st < Const(sPbSignCap, width: 7),
              ]),
              CaseItem(Const(sPbSignCap, width: 7), [
                signReg < sym[0],
                symCount < (symCount + Const(1, width: 12)),
                st < Const(sPbGolChk, width: 7),
              ]),
              CaseItem(Const(sPbGolChk, width: 7), [
                If(
                  pbLevelReg.gte(Const(15, width: 21)),
                  then: [
                    golLeadReg < Const(0, width: 6),
                    st < Const(sPbGolLeadLoad, width: 7),
                  ],
                  orElse: [st < Const(sPbDeq, width: 7)],
                ),
              ]),
              CaseItem(Const(sPbGolLeadLoad, width: 7), [
                st < Const(sPbGolLeadDec, width: 7),
              ]),
              CaseItem(Const(sPbGolLeadDec, width: 7), [
                st < Const(sPbGolLeadCap, width: 7),
              ]),
              CaseItem(Const(sPbGolLeadCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
                If(
                  sym[0] | golLeadReg.gte(Const(31, width: 6)),
                  then: [
                    golXReg < Const(1, width: 21),
                    golCntReg < Const(0, width: 6),
                    If(
                      golLeadReg.eq(Const(0, width: 6)),
                      then: [st < Const(sPbDeq, width: 7)],
                      orElse: [st < Const(sPbGolReadLoad, width: 7)],
                    ),
                  ],
                  orElse: [
                    golLeadReg < (golLeadReg + Const(1, width: 6)),
                    st < Const(sPbGolLeadLoad, width: 7),
                  ],
                ),
              ]),
              CaseItem(Const(sPbGolReadLoad, width: 7), [
                st < Const(sPbGolReadDec, width: 7),
              ]),
              CaseItem(Const(sPbGolReadDec, width: 7), [
                st < Const(sPbGolReadCap, width: 7),
              ]),
              CaseItem(Const(sPbGolReadCap, width: 7), [
                symCount < (symCount + Const(1, width: 12)),
                If(
                  (golCntReg + Const(1, width: 6)).eq(golLeadReg),
                  then: [
                    pbLevelReg <
                        (pbLevelReg +
                                ((golXReg << 1) | sym[0].zeroExtend(21)) -
                                Const(1, width: 21))
                            .getRange(0, 21),
                    st < Const(sPbDeq, width: 7),
                  ],
                  orElse: [
                    golXReg <
                        ((golXReg << 1) | sym[0].zeroExtend(21)).getRange(
                          0,
                          21,
                        ),
                    golCntReg < (golCntReg + Const(1, width: 6)),
                    st < Const(sPbGolReadLoad, width: 7),
                  ],
                ),
              ]),
              CaseItem(Const(sPbDeq, width: 7), [
                // accumulate cul_level + DC sign, place the dequantized coeff.
                culLevelReg <
                    () {
                      final s = (culLevelReg.zeroExtend(21) + pbLevelReg)
                          .getRange(0, 21);
                      return mux(
                        s.gt(Const(63, width: 21)),
                        Const(63, width: 7),
                        s.getRange(0, 7),
                      );
                    }(),
                If(
                  isC0pb,
                  then: [
                    dcSignReg <
                        mux(
                          pbLevelReg.eq(Const(0, width: 21)),
                          Const(0, width: 2),
                          mux<Logic>(
                            signReg,
                            Const(1, width: 2),
                            Const(2, width: 2),
                          ),
                        ),
                  ],
                ),
                ...() {
                  // luma write: 4x4 (coeffsRam[rasterOf]) or 8x8 (rasterOf8).
                  final w4 = <Conditional>[
                    for (var p = 0; p < 16; p++)
                      If(
                        posOfCidx.eq(Const(p, width: 6)),
                        then: [coeffsRam[rasterOf(p)] < dqCoeff!],
                      ),
                  ];
                  // tx-split (depth 1) write: place the 4x4 coeff into the 8x8
                  // raster at the sub-block's origin. subBlk -> (colOff, rowOff).
                  // Raster index within the txb is rasterOf(p), decomposed into
                  // row (>>2) and col (&3), then offset by the sub-block origin.
                  final wSplit = txLeaf
                      ? <Conditional>[
                          for (var sb = 0; sb < 4; sb++)
                            for (var p = 0; p < 16; p++)
                              If(
                                subBlk!.eq(Const(sb, width: 2)) &
                                    posOfCidx.eq(Const(p, width: 6)),
                                then: [
                                  coeffsRam[(((sb >> 1) * 4 +
                                                  (rasterOf(p) >> 2)) *
                                              8) +
                                          (sb & 1) * 4 +
                                          (rasterOf(p) & 3)] <
                                      dqCoeff!,
                                ],
                              ),
                        ]
                      : <Conditional>[];
                  // rect write: place each rect coeff at its row-major raster
                  // (row*txw+col) into the leaf's coeff slot, per rect kind.
                  List<Conditional> rectCoefW(
                    int Function(int) raster,
                    int n,
                  ) => [
                    for (var p = 0; p < n; p++)
                      If(
                        posOfCidx32!.eq(Const(p, width: 7)),
                        then: [coeffsRam[raster(p)] < dqCoeff32!],
                      ),
                  ];
                  final w32 = txLeaf
                      ? <Conditional>[
                          If(
                            rectKindReg!.eq(Const(1, width: 3)),
                            then: rectCoefW(rasterOf48, 32),
                            orElse: [
                              If(
                                rectKindReg.eq(Const(4, width: 3)),
                                then: rectCoefW(rasterOf164, 64),
                                orElse: [
                                  If(
                                    rectKindReg.eq(Const(5, width: 3)),
                                    then: rectCoefW(rasterOf416, 64),
                                    orElse: tx16
                                        ? [
                                            If(
                                              rectKindReg.eq(
                                                Const(2, width: 3),
                                              ),
                                              then: rectCoefW(rasterOf168, 128),
                                              orElse: [
                                                If(
                                                  rectKindReg.eq(
                                                    Const(3, width: 3),
                                                  ),
                                                  then: rectCoefW(
                                                    rasterOf816,
                                                    128,
                                                  ),
                                                  orElse: rectCoefW(
                                                    rasterOf84,
                                                    32,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ]
                                        : rectCoefW(rasterOf84, 32),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ]
                      : <Conditional>[];
                  final lumaWrite = !txLeaf
                      ? w4
                      : <Conditional>[
                          If(
                            leafRect!,
                            then: w32,
                            orElse: [
                              If(
                                leafTx,
                                then: <Conditional>[
                                  for (var p = 0; p < 64; p++)
                                    If(
                                      posOfCidx8!.eq(Const(p, width: 7)),
                                      then: [
                                        coeffsRam[rasterOf8(p)] < dqCoeff8!,
                                      ],
                                    ),
                                ],
                                orElse: [
                                  If(splitActive!, then: wSplit, orElse: w4),
                                ],
                              ),
                            ],
                          ),
                        ];
                  // 16x16 leaf: place each of the 256 coeffs at its raster
                  // position (rasterOf16) into the 256-wide coeff slot.
                  final w16coeff = tx16
                      ? <Conditional>[
                          for (var p = 0; p < 256; p++)
                            If(
                              posOfCidx16!.eq(Const(p, width: 8)),
                              then: [coeffsRam[rasterOf16(p)] < dqCoeff16!],
                            ),
                        ]
                      : <Conditional>[];
                  // 16x16 depth-1 split: place each TX_8X8 sub-block's 64 coeffs
                  // (8x8 raster rasterOf8) into the leaf's 256-wide (16x16 raster)
                  // buffer at the sub-block's 8x8 quadrant (rowOff=subBlk[1],
                  // colOff=subBlk[0]).
                  final wSplit16 = tx16
                      ? <Conditional>[
                          for (var sb = 0; sb < 4; sb++)
                            for (var p = 0; p < 64; p++)
                              If(
                                subBlk!.eq(Const(sb, width: 2)) &
                                    posOfCidx8!.eq(Const(p, width: 7)),
                                then: [
                                  coeffsRam[(((sb >> 1) * 8 +
                                                  (rasterOf8(p) >> 3)) *
                                              16) +
                                          (sb & 1) * 8 +
                                          (rasterOf8(p) & 7)] <
                                      dqCoeff8!,
                                ],
                              ),
                        ]
                      : <Conditional>[];
                  final lumaWriteSized16 = tx16
                      ? <Conditional>[
                          If(
                            split16Active!,
                            then: wSplit16,
                            orElse: [
                              If(
                                leafTx16Reg!,
                                then: w16coeff,
                                orElse: lumaWrite,
                              ),
                            ],
                          ),
                        ]
                      : lumaWrite;
                  // 32x32 / 64x64 leaf: place each of the 1024 coeffs at its
                  // raster position (rasterOf32) into the 1024-wide coeff slot.
                  final wBigCoeff = tx32
                      ? <Conditional>[
                          for (var p = 0; p < 1024; p++)
                            If(
                              posOfCidx32b!.eq(Const(p, width: posW32)),
                              then: [coeffsRam[rasterOf32(p)] < dqCoeff32b!],
                            ),
                        ]
                      : <Conditional>[];
                  final lumaWriteSized = tx32
                      ? <Conditional>[
                          If(
                            leafTx32Reg!,
                            then: wBigCoeff,
                            orElse: lumaWriteSized16,
                          ),
                        ]
                      : lumaWriteSized16;
                  if (!chroma) return lumaWriteSized;
                  // chroma write: a TX_4X4 (8x8 root) or TX_8X8 (16x16 root) block
                  // into uCoeffsRam / vCoeffsRam, selected by the coeff-plane
                  // (1 = U, 2 = V). chroma8 uses the 8x8 scan/raster/dequant.
                  List<Conditional> chromaWrite(List<Logic> ram) => chroma8
                      ? <Conditional>[
                          for (var p = 0; p < 64; p++)
                            If(
                              posOfCidx8!.eq(Const(p, width: 7)),
                              then: [ram[rasterOf8(p)] < dqCoeff8!],
                            ),
                        ]
                      : chroma16
                      ? <Conditional>[
                          for (var p = 0; p < 256; p++)
                            If(
                              posOfCidx16!.eq(Const(p, width: 8)),
                              then: [ram[rasterOf16(p)] < dqCoeff16!],
                            ),
                        ]
                      : chroma422Leaf
                      ? <Conditional>[
                          // TX_8X16: 128 coeffs, row-major raster (8 wide).
                          for (var p = 0; p < 128; p++)
                            If(
                              posOfCidxC422!.eq(Const(p, width: 8)),
                              then: [ram[rasterOf816(p)] < dqCoeffC422!],
                            ),
                        ]
                      : <Conditional>[
                          for (var p = 0; p < 16; p++)
                            If(
                              posOfCidx.eq(Const(p, width: 6)),
                              then: [ram[rasterOf(p)] < dqCoeff!],
                            ),
                        ];
                  final uWrite = chromaWrite(uCoeffsRam);
                  final vWrite = chromaWrite(vCoeffsRam);
                  return <Conditional>[
                    If(
                      isChroma,
                      then: [If(isPlaneV, then: vWrite, orElse: uWrite)],
                      orElse: lumaWriteSized,
                    ),
                  ];
                }(),
                st < Const(sPbNext, width: 7),
              ]),
              CaseItem(Const(sPbNext, width: 7), [
                If(
                  cIdx.eq((eobReg - Const(1, width: 11)).getRange(0, cidxW)),
                  then: [coeffDoneNext()],
                  orElse: [
                    cIdx < (cIdx + Const(1, width: cidxW)),
                    st < Const(sPbCheck, width: 7),
                  ],
                ),
              ]),
              if (txLeaf) ...[
                // tx-split (depth 1) sub-block boundary: snapshot the within-leaf
                // neighbour EC for the sub-block that just finished
                // (subAboveEC[colOff] / subLeftEC[rowOff] = culLevel | dcSign<<6),
                // matching libaom's _setEntropyCtx, then either advance to the
                // next of the four TX_4X4 sub-blocks (clearing the 4x4 levels and
                // the cul_level/dc_sign accumulators) or finish the leaf.
                CaseItem(Const(sSplitNext, width: 7), [
                  ...() {
                    final ecVal =
                        (culLevelReg.zeroExtend(8) |
                                (dcSignReg.zeroExtend(8) << 6))
                            .getRange(0, 8);
                    return <Conditional>[
                      If(
                        splitColOff!.eq(Const(0, width: 1)),
                        then: [subAboveEC[0] < ecVal],
                        orElse: [subAboveEC[1] < ecVal],
                      ),
                      If(
                        splitRowOff!.eq(Const(0, width: 1)),
                        then: [subLeftEC[0] < ecVal],
                        orElse: [subLeftEC[1] < ecVal],
                      ),
                    ];
                  }(),
                  If(
                    subBlk!.eq(Const(3, width: 2)),
                    // all four luma sub-blocks done. With chroma, a chromaRef
                    // leaf now sequences the U then V TX_4X4 chroma blocks
                    // exactly like the TX_8X8 luma->chroma path (clear
                    // splitActive first so the EC/ctx muxes drop back to the
                    // plain chroma banks), otherwise finish the leaf. The
                    // build-time `chroma` guard keeps a chroma==false config
                    // byte-identical (st < sUpd as before).
                    then: chroma
                        ? [
                            // snapshot the luma EC (last sub-block) before the
                            // U/V planes overwrite culLevelReg/dcSignReg, so the
                            // sUpd luma-neighbour write is not chroma-corrupted.
                            lumaEcReg! <
                                (culLevelReg.zeroExtend(8) |
                                        (dcSignReg.zeroExtend(8) << 6))
                                    .getRange(0, 8),
                            splitActive! < Const(0),
                            If(
                              chromaRefV,
                              then: [st < Const(sChromaU, width: 7)],
                              orElse: [st < Const(sUpd, width: 7)],
                            ),
                          ]
                        : [splitActive! < Const(0), st < Const(sUpd, width: 7)],
                    orElse: [
                      subBlk < (subBlk + Const(1, width: 2)),
                      for (var i = 0; i < bufLen; i++)
                        levels[i] < Const(0, width: 8),
                      culLevelReg < Const(0, width: 7),
                      dcSignReg < Const(0, width: 2),
                      st < Const(sTxbDec, width: 7),
                    ],
                  ),
                ]),
                // 16x16 depth-1 sub-block boundary: write this TX_8X8 sub-block's
                // cul_level | dc_sign<<6 into the REAL luma aboveEC/leftEC arrays
                // (two 4x4 units each, at aCol/lRow) so the next sub-block (and the
                // next leaf) read it as their neighbour, exactly like libaom
                // _setEntropyCtx. Then advance to the next TX_8X8 sub-block or, after
                // all four, snapshot the luma EC and enter the chroma / leaf update.
                if (tx16)
                  CaseItem(Const(sSplit16Next, width: 7), [
                    ...() {
                      final ecVal =
                          (culLevelReg.zeroExtend(8) |
                                  (dcSignReg.zeroExtend(8) << 6))
                              .getRange(0, 8);
                      final col = subBlk[0];
                      final row = subBlk[1];
                      final aCol0 = aAbs(
                        (ec2 + (col.zeroExtend(cW) << 1)).getRange(0, cW),
                      );
                      final aCol1 = (aCol0 + Const(1, width: colW)).getRange(
                        0,
                        colW,
                      );
                      final lRow0 = (er + (row.zeroExtend(cW) << 1)).getRange(
                        0,
                        cW,
                      );
                      final lRow1 = (lRow0 + Const(1, width: cW)).getRange(
                        0,
                        cW,
                      );
                      return <Conditional>[
                        for (var k = 0; k < aboveCtxN; k++)
                          If(
                            aCol0.eq(Const(k, width: colW)) |
                                aCol1.eq(Const(k, width: colW)),
                            then: [aboveEC[k] < ecVal],
                          ),
                        for (var k = 0; k < ctxN; k++)
                          If(
                            lRow0.eq(Const(k, width: cW)) |
                                lRow1.eq(Const(k, width: cW)),
                            then: [leftEC[k] < ecVal],
                          ),
                      ];
                    }(),
                    If(
                      subBlk.eq(Const(3, width: 2)),
                      then: chroma
                          ? [
                              lumaEcReg! <
                                  (culLevelReg.zeroExtend(8) |
                                          (dcSignReg.zeroExtend(8) << 6))
                                      .getRange(0, 8),
                              split16Active! < Const(0),
                              If(
                                chromaRefV,
                                then: [st < Const(sChromaU, width: 7)],
                                orElse: [st < Const(sUpd, width: 7)],
                              ),
                            ]
                          : [
                              split16Active! < Const(0),
                              st < Const(sUpd, width: 7),
                            ],
                      orElse: [
                        subBlk < (subBlk + Const(1, width: 2)),
                        for (var i = 0; i < bufLen8; i++)
                          levels8[i] < Const(0, width: 8),
                        culLevelReg < Const(0, width: 7),
                        dcSignReg < Const(0, width: 2),
                        st < Const(sTxbDec, width: 7),
                      ],
                    ),
                  ]),
              ],
              if (chroma) ...[
                // U / V chroma plane setup: clear the shared 4x4 levels buffer and
                // the cul_level/dc_sign accumulators, select the plane, then enter
                // the shared TX_4X4 coeff path (txb_skip + eob + base/br + phase B
                // with the chroma CDF banks via coeffPlane). The U/V coeff RAMs
                // were already cleared at sLeaf.
                CaseItem(Const(sChromaU, width: 7), [
                  // chroma8 clears the TX_8X8 levels buffer (its plane geometry).
                  // TX_4X4 chroma clears the shared 4x4 levels.
                  if (chroma8)
                    for (var i = 0; i < bufLen8; i++)
                      levels8[i] < Const(0, width: 8)
                  else if (chroma16)
                    for (var i = 0; i < bufLen16; i++)
                      levels16[i] < Const(0, width: 8)
                  else if (chroma422Leaf)
                    for (var i = 0; i < bufLenRectB; i++)
                      levels8x16[i] < Const(0, width: 8)
                  else
                    for (var i = 0; i < bufLen; i++)
                      levels[i] < Const(0, width: 8),
                  culLevelReg < Const(0, width: 7),
                  dcSignReg < Const(0, width: 2),
                  coeffPlane! < Const(1, width: 2),
                  st < Const(sTxbDec, width: 7),
                ]),
                CaseItem(Const(sChromaV, width: 7), [
                  if (chroma8)
                    for (var i = 0; i < bufLen8; i++)
                      levels8[i] < Const(0, width: 8)
                  else if (chroma16)
                    for (var i = 0; i < bufLen16; i++)
                      levels16[i] < Const(0, width: 8)
                  else if (chroma422Leaf)
                    for (var i = 0; i < bufLenRectB; i++)
                      levels8x16[i] < Const(0, width: 8)
                  else
                    for (var i = 0; i < bufLen; i++)
                      levels[i] < Const(0, width: 8),
                  culLevelReg < Const(0, width: 7),
                  dcSignReg < Const(0, width: 2),
                  coeffPlane < Const(2, width: 2),
                  st < Const(sTxbDec, width: 7),
                ]),
              ],
            ],
            CaseItem(Const(sUpd, width: 7), [
              ...() {
                final bw4 = romSel(_miWide, eb, 8);
                final bh4 = romSel(_miHigh, eb, 8);
                final pa = romSel(_partCtxAbove, eb, 5);
                final pl = romSel(_partCtxLeft, eb, 5);
                final ec8 = ec2.zeroExtend(8);
                final er8 = er.zeroExtend(8);
                // ABSOLUTE above-write column (Increment 2): the tile-width above-*
                // arrays are written at `sb_c_mi` + the local leaf column. With a
                // root-width tile sbColMi is 0 so this == ec8 (byte-identical).
                final ecA8 = (ec8 + sbColMi.zeroExtend(8)).getRange(0, 8);
                final leafKey =
                    ((er.zeroExtend(32) << 10) |
                            (ec2.zeroExtend(32) << 5) |
                            eb.zeroExtend(32))
                        .getRange(0, 32);
                final modeKey =
                    ((skipReg.zeroExtend(32) << 8) |
                            (ymReg.zeroExtend(32) << 4) |
                            angReg.zeroExtend(32))
                        .getRange(0, 32);
                // leaf log2 size (pixels): miWideLog2[eb] + 2 (8x8 -> 3, 4x4 -> 2).
                final log2size =
                    (romSel(_miWideLog2, eb, 3) + Const(2, width: 3)).getRange(
                      0,
                      3,
                    );
                // tx depth (txLeaf): 0 = TX_8X8 (leafTx=1), 1 = four-TX_4X4 split.
                // A rect leaf reports the decoded depth from txDepthReg (0 for the
                // whole rect tx in this task, depth-1 rect split is deferred).
                final txDepthBase = txLeaf
                    ? mux(
                        leafRect!,
                        txDepthReg!,
                        mux<Logic>(
                          leafTx,
                          Const(0, width: 2),
                          Const(1, width: 2),
                        ),
                      )
                    : Const(0, width: 2);
                // A 16x16 depth-1 (four TX_8X8) leaf reports depth 1, leaf16SplitReg
                // wins over the leafTx-derived txDepthBase (leafTx=1 during the
                // sweep would otherwise read as depth 0).
                final txDepth16 = tx16
                    ? mux(
                        leaf16SplitReg!,
                        Const(1, width: 2),
                        mux(leafTx16Reg!, Const(0, width: 2), txDepthBase),
                      )
                    : txDepthBase;
                final txDepth = tx32
                    ? mux(leafTx32Reg!, Const(0, width: 2), txDepth16)
                    : txDepth16;
                final chk1 = (chk * Const(31, width: 32) + leafKey).getRange(
                  0,
                  32,
                );
                final chk2 = (chk1 * Const(31, width: 32) + modeKey).getRange(
                  0,
                  32,
                );
                // coeff prefix: fold all_zero + tx_type + eob + dequant coeffs.
                final coeffKey =
                    ((allZeroReg.zeroExtend(32) << 5) |
                            txTypeReg.zeroExtend(32))
                        .getRange(0, 32);
                Logic chkFinal;
                if (txLeaf) {
                  // txLeaf chk: leafKey, modeKey, log2size, txDepth, 64 coeffs.
                  var ck =
                      (chk2 * Const(31, width: 32) + log2size.zeroExtend(32))
                          .getRange(0, 32);
                  ck = (ck * Const(31, width: 32) + txDepth.zeroExtend(32))
                      .getRange(0, 32);
                  for (var pos = 0; pos < leafCoeffN; pos++) {
                    ck =
                        (ck * Const(31, width: 32) +
                                coeffsRam[pos].zeroExtend(32))
                            .getRange(0, 32);
                  }
                  chkFinal = ck;
                } else if (coeffPrefix) {
                  var ck = (chk2 * Const(31, width: 32) + coeffKey).getRange(
                    0,
                    32,
                  );
                  ck = (ck * Const(31, width: 32) + eobReg.zeroExtend(32))
                      .getRange(0, 32);
                  for (var pos = 0; pos < 16; pos++) {
                    ck =
                        (ck * Const(31, width: 32) +
                                coeffsRam[pos].zeroExtend(32))
                            .getRange(0, 32);
                  }
                  chkFinal = ck;
                } else {
                  chkFinal = chk2;
                }
                // LUMA neighbour EC value: culLevel | dcSign<<6 of THIS leaf's luma
                // block. For a chroma config the shared culLevelReg/dcSignReg hold
                // the V-plane value here, so use the latched lumaEcReg instead (it
                // was snapshotted when the luma plane finished). A chroma==false
                // config keeps the direct culLevelReg path (byte-identical).
                final ecVal = coeffPrefix
                    ? (chroma
                          ? lumaEcReg!
                          : (culLevelReg.zeroExtend(8) |
                                    (dcSignReg.zeroExtend(8) << 6))
                                .getRange(0, 8))
                    : Const(0, width: 8);
                // A 16x16 depth-1 leaf already wrote per-TX_8X8-sub-block EC values
                // into aboveEC/leftEC during the sweep, the batched single-value
                // write here would clobber them, so suppress it for split leaves.
                final ecKeep = tx16 ? ~leaf16SplitReg! : Const(1);
                // packed palette colours for the neighbour cache: Y[0..7] in bytes
                // 0..7, U[0..7] in bytes 8..15 (matches SW miPalColors).
                final palPacked = enablePalette
                    ? [
                        for (var i = 7; i >= 0; i--) palColU[i],
                        for (var i = 7; i >= 0; i--) palColY[i],
                      ].concat()
                    : Const(0, width: 128);
                return <Conditional>[
                  for (var k = 0; k < aboveCtxN; k++)
                    If(
                      Const(k, width: 8).gte(ecA8) &
                          Const(k, width: 8).lt((ecA8 + bw4).getRange(0, 8)),
                      then: [
                        aboveCtx[k] < pa,
                        aboveSkip[k] < skipReg,
                        aboveYm[k] < ymReg,
                        if (coeffPrefix) If(ecKeep, then: [aboveEC[k] < ecVal]),
                        if (enablePalette) ...[
                          abovePalY[k] < palYSizeReg!,
                          abovePalUV[k] < palUVSizeReg!,
                          abovePalCol[k] < palPacked,
                        ],
                      ],
                    ),
                  for (var k = 0; k < ctxN; k++)
                    If(
                      Const(k, width: 8).gte(er8) &
                          Const(k, width: 8).lt((er8 + bh4).getRange(0, 8)),
                      then: [
                        leftCtx[k] < pl,
                        leftSkip[k] < skipReg,
                        leftYm[k] < ymReg,
                        if (coeffPrefix) If(ecKeep, then: [leftEC[k] < ecVal]),
                        if (enablePalette) ...[
                          leftPalY[k] < palYSizeReg!,
                          leftPalUV[k] < palUVSizeReg!,
                          leftPalCol[k] < palPacked,
                        ],
                      ],
                    ),
                  chk < chkFinal,
                  // txLeaf: maintain the above/left txfm-size context arrays in
                  // pixels (skip -> block pixels, else the leaf tx width/height).
                  // For the whole-SB NONE leaf this is never read back, but it
                  // mirrors `_decodeBlock`'s neighbour update for extension.
                  if (txLeaf) ...[
                    for (var k = 0; k < aboveCtxN; k++)
                      If(
                        Const(k, width: 8).gte(ecA8) &
                            Const(k, width: 8).lt((ecA8 + bw4).getRange(0, 8)),
                        then: [
                          // non-skip tx width (pixels): rect uses the rect tx
                          // width per kind, else leafTx ? 8 : 4.
                          aboveTxfm[k] <
                              mux(
                                skipReg,
                                (bw4 << 2).getRange(0, 7),
                                mux(
                                  leafRect!,
                                  mux(
                                    rectKindReg!.eq(Const(2, width: 3)) |
                                        rectKindReg.eq(Const(4, width: 3)),
                                    Const(16, width: 7),
                                    mux<Logic>(
                                      rectKindReg.eq(Const(1, width: 3)) |
                                          rectKindReg.eq(Const(5, width: 3)),
                                      Const(4, width: 7),
                                      Const(8, width: 7),
                                    ),
                                  ),
                                  tx32
                                      ? mux(
                                          leafTx32Reg!,
                                          mux<Logic>(
                                            leafIs64,
                                            Const(64, width: 7),
                                            Const(32, width: 7),
                                          ),
                                          tx16
                                              ? mux(
                                                  leafTx16Reg!,
                                                  Const(16, width: 7),
                                                  mux<Logic>(
                                                    leafTx,
                                                    Const(8, width: 7),
                                                    Const(4, width: 7),
                                                  ),
                                                )
                                              : mux<Logic>(
                                                  leafTx,
                                                  Const(8, width: 7),
                                                  Const(4, width: 7),
                                                ),
                                        )
                                      : tx16
                                      ? mux(
                                          leafTx16Reg!,
                                          Const(16, width: 7),
                                          mux<Logic>(
                                            leafTx,
                                            Const(8, width: 7),
                                            Const(4, width: 7),
                                          ),
                                        )
                                      : mux<Logic>(
                                          leafTx,
                                          Const(8, width: 7),
                                          Const(4, width: 7),
                                        ),
                                ),
                              ),
                        ],
                      ),
                    for (var k = 0; k < ctxN; k++)
                      If(
                        Const(k, width: 8).gte(er8) &
                            Const(k, width: 8).lt((er8 + bh4).getRange(0, 8)),
                        then: [
                          // non-skip tx height (pixels): rect uses the rect tx
                          // height per kind, else leafTx ? 8 : 4.
                          leftTxfm[k] <
                              mux(
                                skipReg,
                                (bh4 << 2).getRange(0, 7),
                                mux(
                                  leafRect!,
                                  mux(
                                    rectKindReg!.eq(Const(3, width: 3)) |
                                        rectKindReg.eq(Const(5, width: 3)),
                                    Const(16, width: 7),
                                    mux<Logic>(
                                      rectKindReg.eq(Const(1, width: 3)) |
                                          rectKindReg.eq(Const(2, width: 3)),
                                      Const(8, width: 7),
                                      Const(4, width: 7),
                                    ),
                                  ),
                                  tx32
                                      ? mux(
                                          leafTx32Reg!,
                                          mux<Logic>(
                                            leafIs64,
                                            Const(64, width: 7),
                                            Const(32, width: 7),
                                          ),
                                          tx16
                                              ? mux(
                                                  leafTx16Reg!,
                                                  Const(16, width: 7),
                                                  mux<Logic>(
                                                    leafTx,
                                                    Const(8, width: 7),
                                                    Const(4, width: 7),
                                                  ),
                                                )
                                              : mux<Logic>(
                                                  leafTx,
                                                  Const(8, width: 7),
                                                  Const(4, width: 7),
                                                ),
                                        )
                                      : tx16
                                      ? mux(
                                          leafTx16Reg!,
                                          Const(16, width: 7),
                                          mux<Logic>(
                                            leafTx,
                                            Const(8, width: 7),
                                            Const(4, width: 7),
                                          ),
                                        )
                                      : mux<Logic>(
                                          leafTx,
                                          Const(8, width: 7),
                                          Const(4, width: 7),
                                        ),
                                ),
                              ),
                        ],
                      ),
                  ],
                  if (coeffPrefix)
                    for (var j = 0; j < maxLeafOut; j++)
                      If(
                        leafCount.eq(Const(j, width: 12)),
                        then: [
                          ymodeOut[j] < ymReg,
                          angleOut[j] < angReg,
                          if (enableFilterIntra) ...[
                            fiUseOut[j] < fiReg!,
                            fiModeOut[j] < fiModeReg!,
                          ],
                          txtypeOut[j] < txTypeReg,
                          if (txLeaf) ...[
                            log2Out[j] < log2size,
                            // rect kind for recon: 0 = square, 1 + rectKindReg for a
                            // rect leaf (so recon has (bw,bh)).
                            rectKindOut[j] <
                                mux(
                                  leafRect!,
                                  (rectKindReg!.zeroExtend(3) +
                                          Const(1, width: 3))
                                      .getRange(0, 3),
                                  Const(0, width: 3),
                                ),
                            txDepthOut[j] < txDepth,
                          ],
                          for (var i = 0; i < leafCoeffN; i++)
                            coeffsOut[j * leafCoeffN + i] < coeffsRam[i],
                          // MULTI-LEAF chroma: snapshot this leaf's uv_mode / cfl /
                          // U/V dequant coeffs (decoded before this sUpd) into the
                          // per-leaf output arrays. A non-chromaRef leaf keeps its
                          // reset-0 chroma (uvModeReg holds DC / empty coeffs).
                          if (chroma) ...[
                            uvModeOut[j] < uvModeReg,
                            uvAngleOut[j] < angUvReg,
                            cflIdxOut[j] < cflIdxReg,
                            cflSignsOut[j] < cflSignsReg,
                            for (var i = 0; i < chromaN; i++) ...[
                              uCoeffsOut[j * chromaN + i] < uCoeffsRam[i],
                              vCoeffsOut[j * chromaN + i] < vCoeffsRam[i],
                            ],
                          ],
                          // per-leaf palette snapshot.
                          if (enablePalette) ...[
                            palHasYOut[j] < palYSizeReg!.gt(Const(0, width: 4)),
                            palYSizeOut[j] < palYSizeReg,
                            for (var i = 0; i < 8; i++)
                              palYColOut[j * 8 + i] < palColY[i],
                            palYMapChkOut[j] < palMapChkY!,
                            if (chroma) ...[
                              palHasUVOut[j] <
                                  palUVSizeReg!.gt(Const(0, width: 4)),
                              palUVSizeOut[j] < palUVSizeReg,
                              for (var i = 0; i < 8; i++) ...[
                                palUColOut[j * 8 + i] < palColU[i],
                                palVColOut[j * 8 + i] < palColV[i],
                              ],
                              palUVMapChkOut[j] < palMapChkUV!,
                            ],
                          ],
                        ],
                      ),
                  leafCount < (leafCount + Const(1, width: 12)),
                ];
              }(),
              If(
                (emitIdx + Const(1, width: 3)).eq(leafN),
                then: [st < Const(sPop, width: 7)],
                orElse: [
                  emitIdx < (emitIdx + Const(1, width: 3)),
                  st < Const(sLeaf, width: 7),
                ],
              ),
            ]),
            CaseItem(Const(sDone, width: 7), [
              If(~input('start'), then: [st < Const(sIdle, width: 7)]),
            ]),
          ]),
        ],
      ),
    ]);
  }
}
