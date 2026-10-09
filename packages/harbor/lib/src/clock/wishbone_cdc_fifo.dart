import 'package:rohd/rohd.dart';
import 'package:rohd_bridge/rohd_bridge.dart';

import '../soc/target.dart';
import 'cdc.dart';
import 'wishbone_cdc.dart' show stickyCdcError;

/// Wishbone clock-domain-crossing bridge built on async gray-pointer FIFOs.
///
/// Drop-in port-compatible with [HarborWishboneCdcBridge] (the small gray-counter
/// handshake), but crosses the two domains through a request FIFO (slave->master)
/// and a response FIFO (master->slave) instead of a single-outstanding req/done
/// handshake. Each FIFO decouples the domains: the producer advances its write
/// pointer freely and the consumer drains as its synchronized view of that
/// pointer catches up, so the crossing tolerates the pathological fixed phase of
/// two phase-locked clocks (the creek sys/ctrl case where the tight handshake
/// wedged) far better: the payload is captured into FIFO storage and only read
/// out after the gray write-pointer has safely crossed, rather than sampled as a
/// quasi-static multi-cycle path.
///
/// [target] + [blockRam] select request FIFO storage: block RAM on a target that
/// supports it (keeps the depth off the flop budget), else flops. [depth] is the
/// request FIFO depth and [respDepth] the response FIFO depth (powers of two).
/// A deeper request FIFO holds more posted writes in flight.
///
/// With [postedWrites], a WRITE is ACKed on the slave side as soon as its
/// payload is captured into the request FIFO, and the master side pushes no
/// response for it. The slave therefore never waits for a round trip on a
/// write, and up to [depth] writes are in flight while the master domain drains
/// them at its own rate. Reads keep the single-outstanding request/response
/// handshake. Ordering is preserved because both go through the same request
/// FIFO, so a read is always served after every write queued before it. The
/// cost is that a write can no longer report an error, which is what "posted"
/// means. Without the flag the bridge is strictly one transaction in flight.
///
/// A reset of either domain resets both sides and empties both FIFOs. A slave
/// cycle that waits during a master domain reset gets ACK with all-ones data.
/// When the slave aborts a cycle, the bridge drops its response.
/// Each such poison ACK sets the sticky `s_bus_error` output.
class HarborWishboneCdcFifoBridge extends BridgeModule {
  /// Address bus width.
  final int addressWidth;

  /// Data bus width.
  final int dataWidth;

  /// Byte-select width.
  final int selWidth;

  /// Request FIFO depth (power of two, >= 2).
  final int depth;

  /// Response FIFO depth (power of two, >= 2). One response at most is in
  /// flight, because reads go one at a time and posted writes push none.
  final int respDepth;

  /// FPGA target (selects block-RAM vs flop FIFO storage when [blockRam]).
  final HarborDeviceTarget? target;

  /// Back the request FIFO storage with block RAM where [target] supports it.
  final bool blockRam;

  /// ACK a write as soon as the request FIFO captures it, and drop its
  /// response. Lets the slave side stream writes instead of paying a crossing
  /// round trip per word.
  final bool postedWrites;

  HarborWishboneCdcFifoBridge({
    required this.addressWidth,
    required this.dataWidth,
    int? selWidth,
    this.depth = 8,
    this.respDepth = 2,
    this.target,
    this.blockRam = false,
    this.postedWrites = false,
    super.name = 'wishbone_cdc_fifo',
  }) : selWidth = selWidth ?? (dataWidth ~/ 8),
       super(
         _definitionName(
           addressWidth: addressWidth,
           dataWidth: dataWidth,
           selWidth: selWidth ?? (dataWidth ~/ 8),
           depth: depth,
           respDepth: respDepth,
           blockRam: blockRam && target?.blockRam != null,
           posted: postedWrites,
         ),
       ) {
    final sw = this.selWidth;
    final aw = addressWidth;
    final dw = dataWidth;

    createPort('s_clk', PortDirection.input);
    createPort('s_reset', PortDirection.input);
    createPort('s_cyc', PortDirection.input);
    createPort('s_stb', PortDirection.input);
    createPort('s_we', PortDirection.input);
    createPort('s_adr', PortDirection.input, width: aw);
    createPort('s_dat_w', PortDirection.input, width: dw);
    createPort('s_sel', PortDirection.input, width: sw);
    addOutput('s_ack');
    addOutput('s_dat_r', width: dw);

    createPort('m_clk', PortDirection.input);
    createPort('m_reset', PortDirection.input);
    createPort('m_ack', PortDirection.input);
    createPort('m_dat_r', PortDirection.input, width: dw);
    addOutput('m_cyc');
    addOutput('m_stb');
    addOutput('m_we');
    addOutput('m_adr', width: aw);
    addOutput('m_dat_w', width: dw);
    addOutput('m_sel', width: sw);

    final sClk = input('s_clk');
    final mClk = input('m_clk');
    final sReset = harborCdcJoinReset(
      sClk,
      input('s_reset'),
      input('m_reset'),
      name: 's_join_reset',
    );
    final mReset = harborCdcJoinReset(
      mClk,
      input('m_reset'),
      input('s_reset'),
      name: 'm_join_reset',
    );
    // Logic on the master clock behind this bridge must reset with it.
    addOutput('m_reset_joined') <= mReset;
    // Reset only from the master domain while a slave cycle waits.
    final sPeerReset = (sReset & ~input('s_reset')).named('s_peer_reset');

    // Request payload packed { we, adr, dat_w, sel } (MSB..LSB).
    final reqW = 1 + aw + dw + sw;

    final reqFifo = HarborCdcFifo(
      dataWidth: reqW,
      depth: depth,
      target: target,
      blockRam: blockRam,
      name: 'req_fifo',
    );
    // The response FIFO is small, so it always uses flops.
    final respFifo = HarborCdcFifo(
      dataWidth: dw,
      depth: respDepth,
      name: 'resp_fifo',
    );
    addSubModule(reqFifo);
    addSubModule(respFifo);

    final pending = Logic(name: 'pending');
    // The cycle that owns the pending response was aborted.
    final orphan = Logic(name: 'orphan');
    final ackReg = Logic(name: 's_ack_reg');
    final sDatRReg = Logic(name: 's_dat_r_reg', width: dw);

    final sReq = (input('s_cyc') & input('s_stb')).named('s_req');
    final reqFull = reqFifo.output('wr_full');
    // A posted write never sets `pending`, so `~ackReg` alone spaces it: ACK is
    // a one-cycle pulse, and a master that holds its request through the ACK
    // gets exactly one push per ACK, the same as a read.
    final reqPush = (sReq & ~pending & ~ackReg & ~reqFull).named('req_push');
    // A posted write completes entirely on the slave side.
    final postedPush = postedWrites
        ? (reqPush & input('s_we')).named('posted_push')
        : Const(0);
    reqFifo.input('wr_clk').srcConnection! <= sClk;
    reqFifo.input('wr_reset').srcConnection! <= sReset;
    reqFifo.input('wr_en').srcConnection! <= reqPush;
    reqFifo.input('wr_data').srcConnection! <=
        [
          input('s_we'),
          input('s_adr'),
          input('s_dat_w'),
          input('s_sel'),
        ].swizzle();

    final respEmpty = respFifo.output('rd_empty');
    final respPop = (pending & ~respEmpty).named('resp_pop');
    respFifo.input('rd_clk').srcConnection! <= sClk;
    respFifo.input('rd_reset').srcConnection! <= sReset;
    respFifo.input('rd_en').srcConnection! <= respPop;

    final poisonAck = (sPeerReset & pending & ~orphan & sReq).named(
      'poison_ack',
    );
    stickyCdcError(this, sClk, input('s_reset'), poisonAck);

    Sequential(sClk, [
      If(
        sReset,
        then: [
          pending < Const(0),
          orphan < Const(0),
          // A master domain reset ends the waiting cycle with poison data.
          If(
            poisonAck,
            then: [
              ackReg < Const(1),
              sDatRReg < Const(1, width: dw, fill: true),
            ],
            orElse: [ackReg < Const(0)],
          ),
        ],
        orElse: [
          ackReg < Const(0),
          If(
            reqPush,
            then: [
              // A posted write is done here. Anything else waits for the
              // response FIFO to hand back a result.
              If(
                postedPush,
                then: [ackReg < Const(1)],
                orElse: [pending < Const(1)],
              ),
            ],
          ),
          If(
            respPop,
            then: [
              // The response of an aborted cycle is dropped.
              sDatRReg < respFifo.output('rd_data'),
              ackReg < sReq & ~orphan,
              pending < Const(0),
              orphan < Const(0),
            ],
            orElse: [
              If(pending & ~sReq, then: [orphan < Const(1)]),
            ],
          ),
        ],
      ),
    ]);

    output('s_ack') <= ackReg & sReq;
    output('s_dat_r') <= sDatRReg;

    final serving = Logic(name: 'serving');
    final mCycReg = Logic(name: 'm_cyc_reg');

    final reqEmpty = reqFifo.output('rd_empty');
    final respWrFull = respFifo.output('wr_full');
    final startServe = (~reqEmpty & ~serving & ~respWrFull).named(
      'start_serve',
    );
    final complete = (serving & mCycReg & input('m_ack')).named('complete');
    // The top bit of the head says if the transaction in flight is a write.
    // The head stays in the FIFO until completion, so a copy taken at the
    // start of service stays correct and cuts the path from the read port.
    final headWe = Logic(name: 'head_we');
    // A posted write was already ACKed on the slave side. Pushing a response
    // for it would desynchronize the response FIFO from the pending read.
    final respPush = postedWrites
        ? (complete & ~headWe).named('resp_push')
        : complete;

    reqFifo.input('rd_clk').srcConnection! <= mClk;
    reqFifo.input('rd_reset').srcConnection! <= mReset;
    // Keep the head in the FIFO while serving (drives m_adr etc. directly).
    // Pop it only on completion.
    reqFifo.input('rd_en').srcConnection! <= complete;

    respFifo.input('wr_clk').srcConnection! <= mClk;
    respFifo.input('wr_reset').srcConnection! <= mReset;
    respFifo.input('wr_en').srcConnection! <= respPush;
    respFifo.input('wr_data').srcConnection! <= input('m_dat_r');

    Sequential(mClk, [
      If(
        mReset,
        then: [serving < Const(0), mCycReg < Const(0), headWe < Const(0)],
        orElse: [
          If(
            startServe,
            then: [
              serving < Const(1),
              mCycReg < Const(1),
              headWe < reqFifo.output('rd_data').slice(reqW - 1, reqW - 1),
            ],
            orElse: [
              If(complete, then: [serving < Const(0), mCycReg < Const(0)]),
            ],
          ),
        ],
      ),
    ]);

    // Unpack the FIFO head { we, adr, dat_w, sel } onto the master bus. Stable
    // while serving because the head is not popped until completion.
    final head = reqFifo.output('rd_data');
    output('m_cyc') <= mCycReg;
    output('m_stb') <= mCycReg;
    output('m_we') <= head.slice(reqW - 1, reqW - 1);
    output('m_adr') <= head.slice(reqW - 2, reqW - 1 - aw);
    output('m_dat_w') <= head.slice(sw + dw - 1, sw);
    output('m_sel') <= head.slice(sw - 1, 0);

    // Observation tap, port-compatible with HarborWishboneCdcBridge.dbg so the
    // DDR controller's dbg_cdc routing is unchanged. swizzle: first = MSB (bit 7).
    //   [0] pending (slave txn outstanding)   [1] s_ack
    //   [2] serving (master cycle live)       [3] m_cyc
    //   [4] req_fifo not empty (fast sees a request queued)
    //   [5] resp_fifo not empty (slave has a response waiting)
    //   [6] req_fifo full (back-pressure to the slave)
    //   [7] resp_fifo full (back-pressure to the master)
    addOutput('dbg', width: 8) <=
        [
          respFifo.output('wr_full'),
          reqFull,
          ~respEmpty,
          ~reqEmpty,
          mCycReg,
          serving,
          ackReg,
          pending,
        ].swizzle();
  }

  static void _checkDepth(int value, String field) {
    if (value < 2 || (value & (value - 1)) != 0) {
      throw ArgumentError.value(
        value,
        field,
        'must be a power of two and >= 2',
      );
    }
  }

  /// The definition name holds every parameter that changes the structure,
  /// because the name is reserved and two different bridges must not share it.
  /// The configuration of the Arty S7 DDR3 bridge keeps the short name, so its
  /// netlist does not change.
  static String _definitionName({
    required int addressWidth,
    required int dataWidth,
    required int selWidth,
    required int depth,
    required int respDepth,
    required bool blockRam,
    required bool posted,
  }) {
    _checkDepth(depth, 'depth');
    _checkDepth(respDepth, 'respDepth');
    final base = posted
        ? 'HarborWishboneCdcFifoBridgePosted'
        : 'HarborWishboneCdcFifoBridge';
    final arty =
        addressWidth == 64 &&
        dataWidth == 64 &&
        selWidth == 8 &&
        depth == 16 &&
        respDepth == 2 &&
        !blockRam;
    if (arty) return base;
    return '${base}_${addressWidth}a${dataWidth}d${selWidth}s'
        '${depth}q${respDepth}r${blockRam ? '_bram' : ''}';
  }
}
