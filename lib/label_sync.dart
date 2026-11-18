/// Prices and barcodes from the sticker (label printing) app.
///
/// The sticker app's Supabase exposes the active packagings through the
/// read-only function `kassa_verpakkingen()` (PLU, title, contents, price,
/// barcode). For every PLU in that list the sticker app is the truth: its
/// name, price and EAN replace the PLU-file entry. The list is cached, so the
/// kassa keeps working offline.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

const _supabaseUrl = 'https://gxlbqxdloucaisnxmpky.supabase.co';
// Publishable key: safe to ship in the app. It can only call the read-only
// price function; the tables themselves need a login.
const _publishableKey = 'sb_publishable_1GtIrj9YZq1nuI206Fztfg_cod8_0e1';

class LabelItem {
  final int plu;
  final String title;
  final String contents;
  final int priceCents;

  /// Barcode set in the sticker app (13 digits), or empty.
  final String barcode;

  const LabelItem({
    required this.plu,
    required this.title,
    required this.contents,
    required this.priceCents,
    this.barcode = '',
  });

  /// The code printed on the sticker: the barcode from the app, otherwise
  /// "20" + PLU (5) + price in cents (5) + check digit.
  String get ean => barcode.length == 13 ? barcode : storeEan(plu, priceCents);

  factory LabelItem.fromJson(Map<String, dynamic> j) => LabelItem(
        plu: (j['plu'] as num).toInt(),
        title: ((j['titel'] ?? '') as String).trim(),
        contents: ((j['inhoud'] ?? '') as String).trim(),
        priceCents: (num.parse(j['prijs'].toString()) * 100).round(),
        barcode: ((j['barcode'] ?? '') as String).replaceAll(RegExp(r'\D'), ''),
      );

  Map<String, dynamic> toJson() => {
        'plu': plu,
        'titel': title,
        'inhoud': contents,
        'prijs': priceCents / 100,
        'barcode': barcode,
      };
}

Future<List<LabelItem>> fetchLabelItems() async {
  final res = await http
      .post(
        Uri.parse('$_supabaseUrl/rest/v1/rpc/kassa_verpakkingen'),
        headers: {
          'apikey': _publishableKey,
          'Authorization': 'Bearer $_publishableKey',
          'Content-Type': 'application/json',
        },
        body: '{}',
      )
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw Exception('stickerapp gaf status ${res.statusCode}');
  }
  return [
    for (final j in jsonDecode(utf8.decode(res.bodyBytes)) as List)
      LabelItem.fromJson(j as Map<String, dynamic>)
  ];
}

/// EAN-13 check digit for the first 12 digits of [code].
int ean13CheckDigit(String code) {
  var sum = 0;
  for (var i = 0; i < 12; i++) {
    sum += int.parse(code[i]) * (i.isOdd ? 3 : 1);
  }
  return (10 - sum % 10) % 10;
}

bool isValidEan13(String code) =>
    RegExp(r'^\d{13}$').hasMatch(code) &&
    ean13CheckDigit(code) == int.parse(code[12]);

/// In-store code as printed by the sticker app and read by the kassa:
/// "20" + PLU (5 digits) + price in cents (5 digits) + check digit.
String storeEan(int plu, int priceCents) {
  final base =
      '20${plu.toString().padLeft(5, '0')}${priceCents.toString().padLeft(5, '0')}';
  return '$base${ean13CheckDigit(base)}';
}

/// Makes the full 13-digit code where the PLU file has a shortened one:
/// - 11/12 digits that are a valid EAN-13 once the lost leading zeros are
///   added back (UPC codes saved through Excel) get those zeros;
/// - other shortened in-store codes (starting with 2) become the in-store
///   code for this PLU and price.
/// Anything else is left as it is.
String completeEan(String ean, int plu, int priceCents) {
  if (ean.isEmpty || isValidEan13(ean)) return ean;
  if (ean.length == 11 || ean.length == 12) {
    final padded = ean.padLeft(13, '0');
    if (isValidEan13(padded)) return padded;
  }
  if (ean.startsWith('2') && ean.length <= 13) return storeEan(plu, priceCents);
  return ean;
}

/// Applies the sticker app as the truth on top of the PLU-file products.
///
/// For a PLU in [labels] each sticker-app packaging becomes a product with
/// the sticker app's name, contents, price and EAN. The PLU-file entry for
/// that PLU is dropped, unless it has a manufacturer barcode (not starting
/// with 2): then it is a different product that happens to share the PLU
/// number, and it stays so its barcode still scans. Other products get their
/// EAN completed to 13 digits.
List<Product> applyLabelTruth(List<Product> imported, List<LabelItem> labels) {
  final byPlu = <int, List<LabelItem>>{};
  for (final l in labels) {
    byPlu.putIfAbsent(l.plu, () => []).add(l);
  }
  final vatByPlu = {for (final p in imported) p.plu: p.vatPercent};

  final out = <Product>[];
  for (final entry in byPlu.entries) {
    for (final l in entry.value) {
      out.add(Product(
        plu: l.plu,
        name: l.title,
        description: l.contents,
        unit: SaleUnit.piece,
        priceCents: l.priceCents,
        ean: l.ean,
        vatPercent: vatByPlu[l.plu] ?? 9,
        fromLabelApp: true,
      ));
    }
  }
  final labelEans = {for (final p in out) p.ean};
  for (final p in imported) {
    if (byPlu.containsKey(p.plu)) {
      final manufacturerCode = p.ean.isNotEmpty && !p.ean.startsWith('2');
      if (manufacturerCode && !labelEans.contains(p.ean)) out.add(p);
      continue;
    }
    // Per-kg products: the scale label holds a weight, not a price, so a
    // price-based in-store code would be wrong; leave those codes alone.
    if (p.unit == SaleUnit.kg) {
      out.add(p);
      continue;
    }
    final ean = completeEan(p.ean, p.plu, p.priceCents);
    out.add(ean == p.ean ? p : p.copyWith(ean: ean));
  }
  return out;
}
