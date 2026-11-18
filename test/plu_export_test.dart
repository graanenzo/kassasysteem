import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/models.dart';
import 'package:kassasysteem/plu_export.dart';
import 'package:kassasysteem/plu_import.dart';

void main() {
  const products = [
    Product(
        plu: 4,
        name: 'Amandelen bruin',
        description: 'drooggeroosterd',
        unit: SaleUnit.kg,
        priceCents: 1700),
    Product(
        plu: 64,
        name: 'BIO kombucha original',
        unit: SaleUnit.piece,
        priceCents: 259,
        ean: '4015533034770'),
    Product(
        plu: 99,
        name: 'Amerikaans product',
        unit: SaleUnit.piece,
        priceCents: 499,
        ean: '0680275067849'),
  ];

  test('exported xlsx reads back as the same products', () {
    final bytes = exportPluXlsx(products);
    final r = importPluFile(bytes, pluExportFileName(DateTime(2026, 11, 18)));
    expect(r.skippedRows, 1); // header
    expect(r.products.length, products.length);
    for (var i = 0; i < products.length; i++) {
      expect(r.products[i].toJson(), products[i].toJson());
    }
  });

  test('price typed in euros is accepted on import', () {
    final r = parsePluRows([
      ['5', 'Rozijnen', '', 'C', '4,99'],
      ['6', 'Dadels', '', 'C', '3.5'],
      ['7', 'Vijgen', '', 'C', '650'],
    ]);
    expect([for (final p in r.products) p.priceCents], [499, 350, 650]);
  });

  test('file name', () {
    expect(pluExportFileName(DateTime(2026, 1, 5)), 'PLU_export_2026-01-05.xlsx');
  });
}
