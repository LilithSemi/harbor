import 'package:harbor/src/peripherals/sim_dram.dart';
import 'package:test/test.dart';

HarborSimDram _dram({int read = 1, int write = 1}) => HarborSimDram(
  addrWidth: 12,
  dataWidth: 32,
  words: 1024,
  byteSize: 4096,
  readLatency: read,
  writeLatency: write,
);

void main() {
  test('the default keeps the single-cycle model and its name', () {
    final d = _dram();
    expect(d.definitionName, equals('harbor_sim_dram_12a32d1024w'));
    expect(d.simRtl, contains('ack <= stb & ~ack;'));
    expect(d.simRtl, isNot(contains('busy')));
  });

  test('a latency adds a wait counter and changes the name', () {
    final d = _dram(read: 10, write: 7);
    expect(d.definitionName, equals('harbor_sim_dram_12a32d1024w_r10w7'));
    final sv = d.simRtl;
    expect(sv, contains("wire [3:0] lat = we ? 4'd7 : 4'd10;"));
    expect(sv, contains('ack <= fire;'));
    expect(sv, contains('if (fire & we) begin'));
    expect(sv, isNot(contains('ack <= stb & ~ack;')));
  });

  test('two latencies never share a definition name', () {
    expect(
      _dram(read: 2).definitionName,
      isNot(equals(_dram(write: 2).definitionName)),
    );
  });

  test('a latency outside 1 to 1024 throws', () {
    expect(() => _dram(read: 0), throwsArgumentError);
    expect(() => _dram(write: 1025), throwsArgumentError);
  });

  test('latencyFor matches the sdram crossing at 25 MHz', () {
    expect(
      HarborSimDram.latencyFor(busHz: 25000000, memHz: 100000000),
      equals(11),
    );
    expect(
      HarborSimDram.latencyFor(busHz: 25000000, memHz: 125000000),
      equals(10),
    );
  });

  test('an equal read and write latency emits a constant, not a ternary', () {
    final d = _dram(read: 10, write: 10);
    expect(d.simRtl, contains("wire [3:0] lat = 4'd10;"));
    expect(d.simRtl, isNot(contains('lat = we ?')));
  });

  test('every instance carries a cti port for a registered-feedback burst', () {
    for (final d in [_dram(), _dram(read: 10, write: 7)]) {
      expect(d.simRtl, contains('input  logic [2:0]      cti,'));
      expect(d.simRtl, contains("burst_active <= (cti == 3'b010)"));
      expect(d.simRtl, contains('ack <= stb;'));
    }
  });

  test('a scanout port adds scan_clk/scan_reset and a flopped rq_ready', () {
    final d = HarborSimDram(
      addrWidth: 12,
      dataWidth: 32,
      words: 1024,
      byteSize: 4096,
      scanoutPorts: 1,
    );
    final sv = d.simRtl;
    expect(sv, contains('output logic            scan_clk,'));
    expect(sv, contains('output logic            scan_reset,'));
    expect(sv, contains('assign scan_clk = clk;'));
    expect(sv, contains('assign scan_reset = reset;'));
    expect(sv, contains('logic scan0_ready;'));
    expect(sv, contains('assign scan0_rq_ready = scan0_ready;'));
    expect(sv, isNot(contains('assign scan0_rq_ready = (scan0_left')));
  });

  test(
    'scanoutMaxInFlight is validated and only names a non-default value',
    () {
      HarborSimDram make({int ports = 1, int inFlight = 3}) => HarborSimDram(
        addrWidth: 12,
        dataWidth: 32,
        words: 1024,
        byteSize: 4096,
        scanoutPorts: ports,
        scanoutMaxInFlight: inFlight,
      );
      expect(() => make(inFlight: 0), throwsArgumentError);
      expect(() => make(inFlight: 4), throwsArgumentError);
      expect(make().definitionName, endsWith('_s1'));
      expect(make(inFlight: 1).definitionName, endsWith('_s1f1'));
      expect(make(inFlight: 2).definitionName, endsWith('_s1f2'));
      // With no scanout port, scanoutMaxInFlight never shows in the name.
      expect(
        make(ports: 0, inFlight: 1).definitionName,
        equals(_dram().definitionName),
      );
    },
  );

  test('scanoutPorts outside 0..1 throws', () {
    HarborSimDram make(int ports) => HarborSimDram(
      addrWidth: 12,
      dataWidth: 32,
      words: 1024,
      byteSize: 4096,
      scanoutPorts: ports,
    );
    expect(() => make(-1), throwsArgumentError);
    expect(() => make(2), throwsArgumentError);
  });
}
