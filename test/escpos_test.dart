import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/escpos.dart';
import 'package:kassasysteem/models.dart';
import 'package:kassasysteem/settings.dart';

void main() {
  test('ascii transliteration', () {
    expect(EscPosBuilder.ascii('Crème brûlée €'), 'Creme brulee EUR');
  });

  test('receipt builds and ends with cut', () {
    const p = Product(
        plu: 4, name: 'Amandelen bruin', unit: SaleUnit.kg, priceCents: 1700);
    final bytes = buildEscPosReceipt(
      settings: Settings(),
      lines: [CartLine(product: p, unitPriceCents: 425, grams: 250)],
      receiptNo: 1,
      time: DateTime(2026, 11, 13, 12, 0),
    );
    expect(bytes.sublist(bytes.length - 4), [0x1D, 0x56, 0x42, 0x00]);
    expect(String.fromCharCodes(bytes), contains('TOTAAL EUR'));
  });
}
