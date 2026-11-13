/// Holds the imported products, persists them and looks up scans.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';
import 'storage.dart';

class ProductStore {
  List<Product> products = [];
  final Map<String, Product> _byEan = {};
  final Map<int, Product> _byPlu = {};
  int duplicateEans = 0;

  /// Digits only, leading zeros removed, so a 12-digit UPC matches the same
  /// code scanned as 13-digit EAN ("0" + UPC).
  static String normalize(String code) =>
      code.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');

  void setProducts(List<Product> list) {
    products = List.of(list)..sort((a, b) => a.plu.compareTo(b.plu));
    _byEan.clear();
    _byPlu.clear();
    duplicateEans = 0;
    for (final p in products) {
      _byPlu.putIfAbsent(p.plu, () => p);
      final key = normalize(p.ean);
      if (key.isEmpty) continue;
      if (_byEan.containsKey(key)) {
        duplicateEans++; // first product with this code wins
      } else {
        _byEan[key] = p;
      }
    }
  }

  Product? byEan(String code) => _byEan[normalize(code)];
  Product? byPlu(int plu) => _byPlu[plu];

  List<Product> search(String query, {int limit = 40}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final out = <Product>[];
    for (final p in products) {
      if (p.displayName.toLowerCase().contains(q) ||
          p.plu.toString() == q) {
        out.add(p);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  Future<void> load() async {
    // A list imported on this device wins; otherwise use the PLU list that
    // ships with the app.
    var text = await readText('products.json');
    if (text == null) {
      try {
        text = await rootBundle.loadString('assets/products_default.json');
      } catch (_) {
        return;
      }
    }
    final list = jsonDecode(text) as List;
    setProducts([for (final j in list) Product.fromJson(j as Map<String, dynamic>)]);
  }

  Future<void> save() async {
    await writeText(
        'products.json', jsonEncode([for (final p in products) p.toJson()]));
  }
}

/// Result of looking up a scanned code.
class ScanResult {
  final Product product;

  /// Price embedded in an in-store barcode (cents), if any.
  final int? embeddedPriceCents;
  const ScanResult(this.product, [this.embeddedPriceCents]);
}

/// Looks up a scanned code.
///
/// 1. Exact EAN match from the PLU file.
/// 2. In-store / scale label: 13 digits starting with "2", laid out as
///    "20" + PLU (5 digits) + price in cents (5 digits) + check digit,
///    e.g. 2000063015209 = PLU 63, price 15,20.
ScanResult? resolveScan(String code, ProductStore store) {
  final digits = code.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;

  final exact = store.byEan(digits);
  if (exact != null) return ScanResult(exact);

  if (digits.length == 13 && digits.startsWith('2')) {
    final p = store.byPlu(int.parse(digits.substring(2, 7)));
    if (p != null) {
      return ScanResult(p, int.parse(digits.substring(7, 12)));
    }
  }
  return null;
}
