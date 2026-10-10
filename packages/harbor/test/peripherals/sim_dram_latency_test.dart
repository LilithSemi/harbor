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
      equals(10),
    );
    expect(
      HarborSimDram.latencyFor(busHz: 25000000, memHz: 125000000),
      equals(9),
    );
  });
}
