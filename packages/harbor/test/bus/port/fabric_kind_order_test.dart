import 'package:harbor/harbor.dart';
import 'package:test/test.dart';

void main() {
  test('only Wishbone orders a read after an unanswered write', () {
    expect(HarborFabricKind.wishbone.ordersReadAfterWrite, isTrue);
    expect(HarborFabricKind.axi4.ordersReadAfterWrite, isFalse);
    expect(HarborFabricKind.tilelink.ordersReadAfterWrite, isFalse);
  });
}
