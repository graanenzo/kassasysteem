import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/models.dart';
import 'package:kassasysteem/plu_import.dart';
import 'package:kassasysteem/product_store.dart';

List<String> row(int plu, String name, String desc, String type, int price,
        String ean) =>
    [
      '$plu', name.padRight(26), desc.padRight(26), type, '$price',
      '0', '0', '0', '0', '$plu', '0', '1', 'B000', 'P1', 'D0',
      'O000', '0', ean.padRight(13), 'D0',
    ];

void main() {
  final rows = [
    row(4, 'Amandelen bruin', 'drooggeroosterd', 'P', 1700, ''),
    row(63, 'Rode wintertarwe', 'volkorenmeel 5 Kg', 'C', 1520, '2000063015209'),
    row(64, 'BIO kombucha original', '', 'C', 259, '4015533034770'),
    row(99, 'Amerikaans product', '', 'C', 499, '680275067849'),
  ];

  final result = parsePluRows(rows);
  final store = ProductStore()..setProducts(result.products);

  test('import reads all rows', () {
    expect(result.products.length, 4);
    expect(result.weighed, 1);
    expect(store.byPlu(4)!.displayName, 'Amandelen bruin drooggeroosterd');
  });

  test('exact EAN match', () {
    expect(resolveScan('4015533034770', store)!.product.plu, 64);
  });

  test('12-digit UPC matches when scanned as EAN-13', () {
    expect(resolveScan('0680275067849', store)!.product.plu, 99);
  });

  test('scale label for product per kg: 20 + PLU + grams + check', () {
    final r = resolveScan('2000004002659', store)!; // PLU 4, 265 g
    expect(r.product.plu, 4);
    expect(r.product.unit, SaleUnit.kg);
    expect(r.embeddedGrams, 265);
    expect(r.embeddedPriceCents, isNull);
  });

  test('sticker for product per piece: 20 + PLU + price + check', () {
    final r = resolveScan('2000064002598', store)!; // PLU 64, 2,59
    expect(r.product.plu, 64);
    expect(r.embeddedPriceCents, 259);
    expect(r.embeddedGrams, isNull);
  });

  test('unknown code', () {
    expect(resolveScan('8711111111111', store), isNull);
  });

  test('money formatting', () {
    expect(money(1520), '15,20');
    expect(parseEuro('50,5'), 5050);
  });
}
