/// Holds the imported products, persists them and looks up scans.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import 'label_sync.dart';
import 'models.dart';
import 'storage.dart';

class ProductStore {
  /// All products: the PLU list plus products added in the app.
  List<Product> products = [];
  List<Product> _imported = [];

  /// Products added by hand in the app. Kept separately so a new PLU
  /// import does not remove them.
  List<Product> custom = [];

  /// Packagings from the sticker app; their price and EAN win (see
  /// applyLabelTruth). Cached in label_prices.json for offline use.
  List<LabelItem> labels = [];
  DateTime? labelsFetchedAt;
  final Map<String, Product> _byEan = {};
  final Map<int, Product> _byPlu = {};
  int duplicateEans = 0;

  /// Digits only, leading zeros removed, so a 12-digit UPC matches the same
  /// code scanned as 13-digit EAN ("0" + UPC).
  static String normalize(String code) =>
      code.replaceAll(RegExp(r'\D'), '').replaceFirst(RegExp(r'^0+'), '');

  void setProducts(List<Product> list) {
    _imported = List.of(list);
    _rebuild();
  }

  void _rebuild() {
    final merged = cloud ?? applyLabelTruth(_imported, labels);
    // Sort by PLU; within a PLU sticker-app products first, so a typed PLU
    // finds the sticker-app product. (List.sort is not stable, hence the
    // index as last key.)
    final all = [...merged, ...custom];
    final order = List<int>.generate(all.length, (i) => i)
      ..sort((i, j) {
        final a = all[i], b = all[j];
        final c = a.plu.compareTo(b.plu);
        if (c != 0) return c;
        final l = (b.fromLabelApp ? 1 : 0) - (a.fromLabelApp ? 1 : 0);
        return l != 0 ? l : i.compareTo(j);
      });
    products = [for (final i in order) all[i]];
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
    final labelText = await readText('label_prices.json');
    if (labelText != null) {
      final j = jsonDecode(labelText) as Map<String, dynamic>;
      labels = [
        for (final l in j['items'] as List)
          LabelItem.fromJson(l as Map<String, dynamic>)
      ];
      labelsFetchedAt = DateTime.tryParse((j['fetched_at'] ?? '') as String);
    }
    final cloudText = await readText('artikelen.json');
    if (cloudText != null) {
      final j = jsonDecode(cloudText) as Map<String, dynamic>;
      cloud = [
        for (final p in j['items'] as List)
          Product.fromJson(p as Map<String, dynamic>).withLabelFlag(
              (p as Map<String, dynamic>)['sticker'] == true)
      ];
      labelsFetchedAt = DateTime.tryParse((j['fetched_at'] ?? '') as String);
    }
    final customText = await readText('custom_products.json');
    if (customText != null) {
      custom = [
        for (final j in jsonDecode(customText) as List)
          Product.fromJson(j as Map<String, dynamic>)
      ];
    }
    setProducts(
        [for (final j in list) Product.fromJson(j as Map<String, dynamic>)]);
  }

  /// PLU numbers from 90000 up are used for products added in the app.
  int nextCustomPlu() {
    var max = 89999;
    for (final p in custom) {
      if (p.plu > max) max = p.plu;
    }
    return max + 1;
  }

  Future<void> addCustom(Product p) async {
    custom.add(p);
    _rebuild();
    await writeText('custom_products.json',
        jsonEncode([for (final c in custom) c.toJson()]));
  }

  /// Products from Supabase (artikelen). When present this is the whole
  /// list and the PLU file / sticker-app merge is no longer used.
  List<Product>? cloud;

  /// Fetches the product list from Supabase, uses it and caches it for
  /// offline use. Products added at this till while offline are sent
  /// first. Returns how many products got a different price.
  Future<int> syncLabels() async {
    await _pushPending();
    final fresh = await fetchArticles();
    if (fresh.isEmpty) throw Exception('de database gaf een lege lijst');
    final before = <int, Set<int>>{};
    for (final p in products) {
      before.putIfAbsent(p.plu, () => {}).add(p.priceCents);
    }
    cloud = fresh;
    labelsFetchedAt = DateTime.now();
    _rebuild();
    await writeText(
        'artikelen.json',
        jsonEncode({
          'fetched_at': labelsFetchedAt!.toIso8601String(),
          'items': [for (final p in fresh) p.toJson()..['sticker'] = p.fromLabelApp],
        }));
    var changed = 0;
    for (final p in products) {
      final b = before[p.plu];
      if (b != null && !b.contains(p.priceCents)) changed++;
    }
    return changed;
  }

  /// Products added at this till that are not in Supabase yet.
  Future<void> _pushPending() async {
    if (custom.isEmpty) return;
    final left = <Product>[];
    for (final c in custom) {
      try {
        await addArticle(
            name: c.displayName,
            priceCents: c.priceCents,
            ean: c.ean,
            vatPercent: c.vatPercent,
            till: 'offline toegevoegd');
      } catch (_) {
        left.add(c);
      }
    }
    if (left.length != custom.length) {
      custom = left;
      await writeText('custom_products.json',
          jsonEncode([for (final c in custom) c.toJson()]));
    }
  }

  /// Saves a product added at the till in Supabase, so it is known on all
  /// tills at once. Offline it is kept here and sent at the next sync.
  /// Returns the product as it is now in the list.
  Future<Product> addToDatabase(Product p, {required String till}) async {
    try {
      final plu = await addArticle(
          name: p.displayName,
          priceCents: p.priceCents,
          ean: p.ean,
          vatPercent: p.vatPercent,
          till: till);
      final saved = Product(
          plu: plu,
          name: p.name,
          description: p.description,
          unit: p.unit,
          priceCents: p.priceCents,
          ean: p.ean,
          vatPercent: p.vatPercent);
      cloud = [...?cloud, saved];
      _rebuild();
      // Refresh in the background so the other fields come along too.
      syncLabels().catchError((_) => 0);
      return saved;
    } catch (_) {
      await addCustom(p);
      return p;
    }
  }

  int get labelProductCount => products.where((p) => p.fromLabelApp).length;

  /// Number of products in the list from Supabase.
  int get cloudCount => cloud?.length ?? 0;

  /// Replaces the PLU list with an imported one and saves it. Products added
  /// in the app that are also in the imported file (e.g. because an exported
  /// list was edited and read back) are taken over by the file, so they do
  /// not appear twice.
  Future<void> replaceImported(List<Product> list) async {
    final plus = {for (final p in list) p.plu};
    final before = custom.length;
    custom = [for (final c in custom) if (!plus.contains(c.plu)) c];
    setProducts(list);
    await save();
    if (custom.length != before) {
      await writeText('custom_products.json',
          jsonEncode([for (final c in custom) c.toJson()]));
    }
  }

  Future<void> save() async {
    await writeText(
        'products.json', jsonEncode([for (final p in _imported) p.toJson()]));
  }
}

/// Result of looking up a scanned code.
class ScanResult {
  final Product product;

  /// Price embedded in an in-store barcode (cents), for products per piece.
  final int? embeddedPriceCents;

  /// Weight embedded in a scale label (grams), for products per kg.
  final int? embeddedGrams;
  const ScanResult(this.product,
      {this.embeddedPriceCents, this.embeddedGrams});
}

/// Looks up a scanned code.
///
/// 1. Exact EAN match from the PLU file.
/// 2. In-store / scale label: 13 digits starting with "2", laid out as
///    "20" + PLU (5 digits) + value (5 digits) + check digit. The value is
///    - the price in cents for products per piece (sticker app),
///      e.g. 2000063015209 = PLU 63, price 15,20;
///    - the weight in grams for products per kg (scale),
///      e.g. 2000002002659 = PLU 2, 265 g.
ScanResult? resolveScan(String code, ProductStore store) {
  final digits = code.replaceAll(RegExp(r'\D'), '');
  if (digits.isEmpty) return null;

  final exact = store.byEan(digits);
  if (exact != null) return ScanResult(exact);

  if (digits.length == 13 && digits.startsWith('2')) {
    final p = store.byPlu(int.parse(digits.substring(2, 7)));
    if (p != null) {
      final value = int.parse(digits.substring(7, 12));
      return p.unit == SaleUnit.kg
          ? ScanResult(p, embeddedGrams: value)
          : ScanResult(p, embeddedPriceCents: value);
    }
  }
  return null;
}
