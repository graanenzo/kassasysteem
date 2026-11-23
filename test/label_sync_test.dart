import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/label_sync.dart';
import 'package:kassasysteem/models.dart';
import 'package:kassasysteem/product_store.dart';

void main() {
  test('store EAN matches what the sticker app prints', () {
    expect(storeEan(271, 255), '2000271002558');
    expect(storeEan(1041, 1300), '2001041013002');
    expect(storeEan(94, 1985), '2000094019856');
  });

  test('completeEan', () {
    // UPC that lost its leading zero in Excel.
    expect(completeEan('680275067849', 162, 399), '0680275067849');
    // Shortened in-store code -> full in-store code for PLU and price.
    expect(completeEan('20001050140', 105, 145), storeEan(105, 145));
    // Valid codes and unknown short codes stay as they are.
    expect(completeEan('4015533034770', 64, 259), '4015533034770');
    expect(completeEan('54061057', 519, 100), '54061057');
    expect(completeEan('', 1, 100), storeEan(1, 100));
    // Check digit cut off.
    expect(completeEan('842853230047', 851, 165), '8428532300474');
  });

  final imported = [
    const Product(
        plu: 1064,
        name: 'Pumkin spice chikko',
        unit: SaleUnit.kg,
        priceCents: 759,
        ean: '8719689079796'),
    const Product(
        plu: 2, name: 'abrikozen', unit: SaleUnit.kg, priceCents: 1400),
    const Product(
        plu: 63,
        name: 'Rode wintertarwe',
        description: 'volkorenmeel 5 Kg',
        unit: SaleUnit.piece,
        priceCents: 1520,
        ean: '2000063015209'),
    const Product(
        plu: 149,
        name: 'Verse Graaseieren',
        unit: SaleUnit.piece,
        priceCents: 425),
    // Same PLU as a sticker-app product, but a different (bought-in) product.
    const Product(
        plu: 193,
        name: 'bieslookspread',
        unit: SaleUnit.piece,
        priceCents: 349,
        ean: '4019736012535'),
    const Product(
        plu: 105,
        name: 'Appelstukjes 100 g',
        unit: SaleUnit.piece,
        priceCents: 145,
        ean: '20001050140'),
  ];
  const labels = [
    LabelItem(
        plu: 63,
        title: 'Rode wintertarwe volkorenmeel (B)',
        contents: '5 kilo',
        priceCents: 1890),
    LabelItem(plu: 149, title: 'Eieren', contents: '6 eieren', priceCents: 295),
    LabelItem(
        plu: 149, title: 'Eieren', contents: '10 eieren', priceCents: 425),
    LabelItem(
        plu: 193, title: 'Roggebloem', contents: '5 kilo', priceCents: 805),
  ];

  final store = ProductStore()
    ..labels = labels
    ..setProducts(imported);

  test('sticker app wins for its PLUs', () {
    final p = store.byPlu(63)!;
    expect(p.priceCents, 1890);
    expect(p.ean, '2000063018903');
    expect(p.fromLabelApp, isTrue);
    expect(p.displayName, 'Rode wintertarwe volkorenmeel (B) 5 kilo');
    expect(store.products.where((p) => p.plu == 63).length, 1);
  });

  test('two packagings on one PLU become two products', () {
    final eggs = store.products.where((p) => p.plu == 149).toList();
    expect([for (final e in eggs) e.priceCents], [295, 425]);
    expect(resolveScan(storeEan(149, 425), store)!.product.description,
        '10 eieren');
  });

  test('other product with the same PLU keeps its own barcode', () {
    expect(store.byPlu(193)!.name, 'Roggebloem');
    expect(resolveScan('4019736012535', store)!.product.name, 'bieslookspread');
  });

  test('shortened codes are completed, per-kg products untouched', () {
    expect(store.byPlu(105)!.ean, storeEan(105, 145));
    expect(store.byPlu(2)!.ean, '');
    expect(store.byPlu(2)!.unit, SaleUnit.kg);
  });

  test('scale label of a per-kg product gives the weight', () {
    final r = resolveScan('2000002002659', store)!;
    expect(r.product.plu, 2);
    expect(r.embeddedGrams, 265);
  });

  test('old sticker keeps its printed price', () {
    final r = resolveScan('2000063015209', store)!;
    expect(r.product.plu, 63);
    expect(r.embeddedPriceCents, 1520);
  });

  test('new PLU in the sticker app is scannable without PLU file entry', () {
    final s = ProductStore()
      ..labels = const [
        LabelItem(plu: 1099, title: 'Nieuw', contents: '1 kilo', priceCents: 450),
      ]
      ..setProducts(imported);
    expect(s.byPlu(1099)!.name, 'Nieuw');
    final r = resolveScan(storeEan(1099, 450), s)!;
    expect(r.product.plu, 1099);
  });

  test('product with a manufacturer barcode is never per kg', () {
    final r = resolveScan('8719689079796', store)!;
    expect(r.product.plu, 1064);
    expect(r.product.unit, SaleUnit.piece);
  });

  test('crackers tamme kastanje scan by EAN', () {
    final s = ProductStore()
      ..setProducts(const [
        Product(
            plu: 1038,
            name: 'crackers tamme kastanje',
            unit: SaleUnit.piece,
            priceCents: 429,
            ean: '3380380037382'),
      ]);
    expect(resolveScan('3380380037382', s)!.product.plu, 1038);
  });

  test('articles from Supabase become products', () {
    final kg = articleFromJson({
      'plu': 4, 'naam': 'Amandelen bruin drooggeroosterd', 'omschrijving': '',
      'prijs': 17, 'barcode': '', 'per_kg': true, 'btw': 9, 'sticker': false,
    });
    expect(kg.unit, SaleUnit.kg);
    expect(kg.priceCents, 1700);
    expect(kg.ean, '');
    final piece = articleFromJson({
      'plu': 851, 'naam': 'Ecomil kookroom amandel', 'omschrijving': '',
      'prijs': '1.65', 'barcode': '842853230047', 'per_kg': false, 'btw': 9,
      'sticker': false,
    });
    expect(piece.unit, SaleUnit.piece);
    expect(piece.ean, '8428532300474');
    final label = articleFromJson({
      'plu': 271, 'naam': 'Granola', 'omschrijving': '500 gram',
      'prijs': 2.55, 'barcode': '', 'per_kg': false, 'btw': 9, 'sticker': true,
    });
    expect(label.fromLabelApp, isTrue);
    expect(label.ean, storeEan(271, 255));
    expect(label.displayName, 'Granola 500 gram');
  });
}
