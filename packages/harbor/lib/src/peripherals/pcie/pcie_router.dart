import 'package:rohd/rohd.dart';

import 'pcie_stream.dart';

/// One client of a [HarborPcieRouter].
class HarborPcieRouterClient {
  /// Prefix of the client ports on the router.
  final String name;

  /// Bits of the 22 bit `user` that this client claims, for example
  /// [HarborPcieStream.userBar0]. Only bits 8:2 are allowed.
  final int barMask;

  /// True when this client receives completions.
  final bool takesCompletions;

  /// Packets the router sends to the client.
  final HarborPcieStream rx;

  /// Packets the client sends to the router.
  final HarborPcieStream tx;

  HarborPcieRouterClient({
    required this.name,
    required this.barMask,
    required this.rx,
    required this.tx,
    this.takesCompletions = false,
  });
}

/// Routes the packets of a PCIe endpoint stream to clients.
///
/// The router decides on the first beat of each packet. A completion goes to
/// the client with `takesCompletions`. Other packets go to the client whose
/// `barMask` matches `rx_user`. A non-posted request that no client claims
/// gets an Unsupported Request completion from the router. Other unclaimed
/// packets are dropped. A packet is never split between clients.
///
/// Packets from the clients and from the router go to the upstream TX with a
/// round robin arbiter. The arbiter keeps a grant until the last beat.
class HarborPcieRouter extends Module {
  /// Data width in bits, 64 or 128.
  final int width;

  /// The clients of this router.
  final List<HarborPcieRouterClient> clients;

  /// Creates a router. [upstreamRx] carries packets from the endpoint and
  /// [upstreamTx] carries packets to the endpoint.
  HarborPcieRouter({
    required Logic clk,
    required Logic reset,
    required this.width,
    required Logic completerId,
    required HarborPcieStream upstreamRx,
    required HarborPcieStream upstreamTx,
    required this.clients,
    super.name = 'pcie_router',
  }) : super(definitionName: _definitionName(width, clients)) {
    _validate(width, clients, upstreamRx, upstreamTx);
    clk = addInput('clk', clk);
    reset = addInput('reset', reset);
    completerId = addInput('completer_id', completerId, width: 16);

    final rx = HarborPcieStream.addSink(this, upstreamRx);
    final tx = HarborPcieStream.addSource(this, upstreamTx);
    final toClient = [
      for (final c in clients)
        HarborPcieStream.addSource(this, c.rx, prefix: '${c.name}_rx_'),
    ];
    final fromClient = [
      for (final c in clients)
        HarborPcieStream.addSink(this, c.tx, prefix: '${c.name}_tx_'),
    ];

    final urRequest = _buildRx(clk, reset, rx, toClient);
    _buildTx(clk, reset, completerId, tx, fromClient, urRequest);
  }

  static String _definitionName(int width, List<HarborPcieRouterClient> cs) =>
      'HarborPcieRouter_W${width}_'
      '${cs.map((c) => '${c.name}_${c.barMask.toRadixString(16)}'
          '${c.takesCompletions ? 'c' : 'n'}').join('_')}';

  static void _validate(
    int width,
    List<HarborPcieRouterClient> clients,
    HarborPcieStream upstreamRx,
    HarborPcieStream upstreamTx,
  ) {
    final names = <String>{};
    var claimed = 0;
    var completionClients = 0;
    for (final c in clients) {
      if (!names.add(c.name)) {
        throw ArgumentError('duplicate client name ${c.name}');
      }
      for (final s in [c.rx, c.tx, upstreamRx, upstreamTx]) {
        if (s.width != width) {
          throw ArgumentError('stream width ${s.width} differs from $width');
        }
      }
      if (c.barMask & ~0x1fc != 0) {
        throw ArgumentError('barMask of ${c.name} is outside user[8:2]');
      }
      if (c.barMask & claimed != 0) {
        throw ArgumentError('barMask of ${c.name} overlaps another client');
      }
      claimed |= c.barMask;
      if (c.takesCompletions) completionClients++;
    }
    if (completionClients > 1) {
      throw ArgumentError('more than one client takes completions');
    }
  }

  static Logic _or(Iterable<Logic> signals) =>
      signals.isEmpty ? Const(0) : signals.reduce((a, b) => a | b);

  /// Builds the RX side. Returns the pending UR request as
  /// (pending, requester ID, tag).
  (Logic, Logic, Logic, Logic, Logic) _buildRx(
    Logic clk,
    Logic reset,
    HarborPcieStream rx,
    List<HarborPcieStream> toClient,
  ) {
    final n = clients.length;
    final inPacket = Logic(name: 'rx_in_packet');
    final selReg = Logic(name: 'rx_sel_reg', width: n + 2);
    final urPending = Logic(name: 'ur_pending');
    final urRequester = Logic(name: 'ur_requester', width: 16);
    final urTag = Logic(name: 'ur_tag', width: 8);
    final urTc = Logic(name: 'ur_tc', width: 3);
    final urAttr = Logic(name: 'ur_attr', width: 2);

    final first = ~inPacket;
    final fmt = rx.data.slice(31, 29);
    final type = rx.data.slice(28, 24);
    final isCpl = type.eq(0x0a) & ~fmt[2] & ~fmt[0];
    final hasData = fmt[1];
    final nonPosted =
        (type.eq(0) | type.eq(1)) & ~hasData |
        type.eq(2) |
        type.eq(4) |
        type.eq(5) |
        (type.eq(0x0c) | type.eq(0x0d) | type.eq(0x0e)) & hasData;

    final hits = <Logic>[];
    Logic earlier = Const(0);
    for (final c in clients) {
      final barHit = c.barMask == 0
          ? Const(0)
          : (rx.user & Const(c.barMask, width: HarborPcieStream.userWidth))
                .or();
      final raw = mux(isCpl, Const(c.takesCompletions ? 1 : 0), barHit);
      hits.add(raw & ~earlier);
      earlier = earlier | raw;
    }
    final anyHit = _or(hits);
    final ur = ~anyHit & nonPosted & ~isCpl;
    final drop = ~anyHit & ~ur;
    final decoded = [...hits, ur, drop].rswizzle();
    final sel = mux(first, decoded, selReg);
    final selUr = sel[n];
    final selDrop = sel[n + 1];

    final readyTerms = <Logic>[
      for (var i = 0; i < n; i++) sel[i] & toClient[i].ready,
      selUr & (~first | ~urPending),
      selDrop,
    ];
    rx.ready <= _or(readyTerms);

    for (var i = 0; i < n; i++) {
      toClient[i].data <= rx.data;
      toClient[i].keep <= rx.keep;
      toClient[i].last <= rx.last;
      toClient[i].user <= rx.user;
      toClient[i].valid <= rx.valid & sel[i];
    }

    final fire = rx.valid & rx.ready;
    Sequential(clk, [
      If(
        reset,
        then: [inPacket < 0, selReg < 0, urPending < 0],
        orElse: [
          If(
            fire,
            then: [
              If(rx.last, then: [inPacket < 0], orElse: [inPacket < 1]),
              If(first, then: [selReg < decoded]),
              If(
                first & selUr,
                then: [
                  urPending < 1,
                  urRequester < rx.data.slice(63, 48),
                  urTag < rx.data.slice(47, 40),
                  urTc < rx.data.slice(22, 20),
                  urAttr < rx.data.slice(13, 12),
                ],
              ),
            ],
          ),
          If(_urDone, then: [urPending < 0]),
        ],
      ),
    ]);
    return (urPending, urRequester, urTag, urTc, urAttr);
  }

  final Logic _urDone = Logic(name: 'ur_done');

  void _buildTx(
    Logic clk,
    Logic reset,
    Logic completerId,
    HarborPcieStream tx,
    List<HarborPcieStream> fromClient,
    (Logic, Logic, Logic, Logic, Logic) urRequest,
  ) {
    final (urPending, urRequester, urTag, urTc, urAttr) = urRequest;
    final n = clients.length + 1;

    // The UR slot is the last source.
    final urBeat = Logic(name: 'ur_beat');
    final dw0 = [
      Const(0x0a, width: 8),
      Const(0, width: 1),
      urTc,
      Const(0, width: 6),
      urAttr,
      Const(0, width: 12),
    ].swizzle();
    final dw1 = [completerId, Const(1 << 13 | 4, width: 16)].swizzle();
    final dw2 = [urRequester, urTag, Const(0, width: 8)].swizzle();
    final Logic urData;
    final Logic urKeep;
    final Logic urLast;
    if (width == 64) {
      urData = mux(
        urBeat,
        [Const(0, width: 32), dw2].swizzle(),
        [dw1, dw0].swizzle(),
      );
      urKeep = mux(urBeat, Const(0x0f, width: 8), Const(0xff, width: 8));
      urLast = urBeat;
    } else {
      urData = [Const(0, width: 32), dw2, dw1, dw0].swizzle();
      urKeep = Const(0x0fff, width: 16);
      urLast = Const(1);
    }

    final valid = [for (final s in fromClient) s.valid, urPending];
    final datas = [for (final s in fromClient) s.data, urData];
    final keeps = [for (final s in fromClient) s.keep, urKeep];
    final lasts = [for (final s in fromClient) s.last, urLast];
    final users = [
      for (final s in fromClient) s.user,
      Const(0, width: HarborPcieStream.userWidth),
    ];

    final locked = Logic(name: 'tx_locked');
    final grant = Logic(name: 'tx_grant', width: n);
    final lastGrant = Logic(name: 'tx_last_grant', width: n);

    // Round robin: the source after the last granted one has top priority.
    final pick = <Logic>[];
    for (var i = 0; i < n; i++) {
      final terms = <Logic>[];
      for (var l = 0; l < n; l++) {
        final distance = (i - l) % n == 0 ? n : (i - l) % n;
        Logic blocked = Const(0);
        for (var k = 1; k < distance; k++) {
          blocked = blocked | valid[(l + k) % n];
        }
        terms.add(lastGrant[l] & valid[i] & ~blocked);
      }
      pick.add(_or(terms));
    }
    final current = [
      for (var i = 0; i < n; i++) mux(locked, grant[i], pick[i]),
    ];

    Logic select(List<Logic> sources) => _or([
      for (var i = 0; i < n; i++)
        mux(current[i], sources[i], Const(0, width: sources[i].width)),
    ]);

    tx.data <= select(datas);
    tx.keep <= select(keeps);
    tx.last <= select(lasts);
    tx.user <= select(users);
    tx.valid <= _or([for (var i = 0; i < n; i++) current[i] & valid[i]]);

    for (var i = 0; i < fromClient.length; i++) {
      fromClient[i].ready <= current[i] & tx.ready;
    }
    final urFire = current[n - 1] & urPending & tx.ready;
    _urDone <= urFire & urLast;

    final fire = tx.valid & tx.ready;
    final currentWord = current.rswizzle();
    Sequential(clk, [
      If(
        reset,
        then: [
          locked < 0,
          grant < 0,
          lastGrant < Const(1 << (n - 1), width: n),
          urBeat < 0,
        ],
        orElse: [
          If(
            fire,
            then: [
              If(
                tx.last,
                then: [locked < 0, lastGrant < currentWord],
                orElse: [locked < 1, grant < currentWord],
              ),
            ],
            orElse: [
              // Hold the source while a presented beat waits for ready.
              If(tx.valid, then: [locked < 1, grant < currentWord]),
            ],
          ),
          If(
            urFire,
            then: [
              If(urLast, then: [urBeat < 0], orElse: [urBeat < 1]),
            ],
          ),
        ],
      ),
    ]);
  }
}
