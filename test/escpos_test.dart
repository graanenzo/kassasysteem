import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
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

  test('logo becomes ESC * bit image bands', () {
    final logo = img.Image(width: 100, height: 50);
    img.fill(logo, color: img.ColorRgb8(0, 0, 0));
    final b = EscPosBuilder(33)..image(logo);
    final bytes = b.bytes;
    // capped at 180 dots wide, 45 rows -> 6 bands of ESC * 1
    var bands = 0;
    for (var i = 0; i + 2 < bytes.length; i++) {
      if (bytes[i] == 0x1B && bytes[i + 1] == 0x2A && bytes[i + 2] == 1) bands++;
    }
    expect(bands, 6);
  });

  test('staff discount on receipt and VAT over discounted amount', () {
    const a = Product(
        plu: 1, name: 'Granola', unit: SaleUnit.piece, priceCents: 265);
    const b = Product(
        plu: 2, name: 'Tas', unit: SaleUnit.piece, priceCents: 1000,
        vatPercent: 21);
    final lines = [
      CartLine(product: a, unitPriceCents: 265),
      CartLine(product: b, unitPriceCents: 1000),
    ];
    final t = saleTotals(lines, discountPercent: 10);
    expect(t.subtotal, 1265);
    expect(t.discount, 27 + 100);
    expect(t.total, 1138);
    expect(t.byRate, {9: 238, 21: 900});

    final text = String.fromCharCodes(buildEscPosReceipt(
      settings: Settings(),
      lines: lines,
      receiptNo: 2,
      time: DateTime(2026, 11, 19, 12, 0),
      discountPercent: 10,
    ));
    expect(text, contains('Personeelskorting 10%'));
    expect(text, contains('-1,27'));
    expect(text, contains('11,38'));

    expect(saleTotals(lines).discount, 0);
  });
}
