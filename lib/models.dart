/// Data models for the POS: products from the PLU file and cart lines.
library;

enum SaleUnit { piece, kg }

class Product {
  final int plu;
  final String name;
  final String description;
  final SaleUnit unit;

  /// Price in cents: per piece, or per kg when [unit] is [SaleUnit.kg].
  final int priceCents;

  /// Barcode as digits only (may be empty).
  final String ean;
  final int vatPercent;

  /// Price and EAN come from the sticker app (not saved; set on merge).
  final bool fromLabelApp;

  const Product({
    required this.plu,
    required this.name,
    this.description = '',
    required this.unit,
    required this.priceCents,
    this.ean = '',
    this.vatPercent = 9,
    this.fromLabelApp = false,
  });

  Product copyWith({String? ean, SaleUnit? unit}) => Product(
        plu: plu,
        name: name,
        description: description,
        unit: unit ?? this.unit,
        priceCents: priceCents,
        ean: ean ?? this.ean,
        vatPercent: vatPercent,
        fromLabelApp: fromLabelApp,
      );

  String get displayName =>
      description.isEmpty ? name : '$name $description';

  Map<String, dynamic> toJson() => {
        'plu': plu,
        'name': name,
        'description': description,
        'unit': unit.name,
        'price': priceCents,
        'ean': ean,
        'vat': vatPercent,
      };

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        plu: j['plu'] as int,
        name: j['name'] as String,
        description: (j['description'] ?? '') as String,
        unit: j['unit'] == 'kg' ? SaleUnit.kg : SaleUnit.piece,
        priceCents: j['price'] as int,
        ean: (j['ean'] ?? '') as String,
        vatPercent: (j['vat'] ?? 9) as int,
      );
}

class CartLine {
  final Product product;

  /// Price of one unit of this line in cents. For weighed products this is
  /// the price of the weighed portion.
  final int unitPriceCents;

  /// Weight in grams for weighed products, otherwise null.
  final int? grams;
  int quantity;

  CartLine({
    required this.product,
    required this.unitPriceCents,
    this.grams,
    this.quantity = 1,
  });

  int get totalCents => unitPriceCents * quantity;
}

/// Formats cents as "12,34" (Dutch notation, without currency sign).
String money(int cents) {
  final neg = cents < 0;
  final c = cents.abs();
  return '${neg ? '-' : ''}${c ~/ 100},${(c % 100).toString().padLeft(2, '0')}';
}

String euro(int cents) => '€ ${money(cents)}';

/// Parses "50", "50,00" or "50.5" into cents. Returns null if invalid.
int? parseEuro(String s) {
  final t = s.trim().replaceAll(',', '.');
  final v = double.tryParse(t);
  if (v == null || v < 0) return null;
  return (v * 100).round();
}

/// Totals of a sale, with an optional discount (percentage) on everything.
class SaleTotals {
  /// Sum of all lines before discount, in cents.
  final int subtotal;

  /// Discount in cents (0 without discount).
  final int discount;
  final int discountPercent;

  /// Amount per VAT rate after discount (VAT included), in cents.
  final Map<int, int> byRate;

  const SaleTotals({
    required this.subtotal,
    required this.discount,
    required this.discountPercent,
    required this.byRate,
  });

  int get total => subtotal - discount;

  /// VAT included in [byRate], per rate.
  Map<int, int> get vatByRate => {
        for (final e in byRate.entries)
          e.key: (e.value * e.key / (100 + e.key)).round()
      };
}

/// Computes the totals of [lines]. The discount is worked out per VAT rate,
/// so the VAT on the receipt is calculated over the discounted amounts.
SaleTotals saleTotals(List<CartLine> lines, {int discountPercent = 0}) {
  final gross = <int, int>{};
  for (final l in lines) {
    gross.update(l.product.vatPercent, (v) => v + l.totalCents,
        ifAbsent: () => l.totalCents);
  }
  var subtotal = 0;
  var discount = 0;
  final byRate = <int, int>{};
  for (final e in gross.entries) {
    final d = (e.value * discountPercent / 100).round();
    subtotal += e.value;
    discount += d;
    byRate[e.key] = e.value - d;
  }
  return SaleTotals(
    subtotal: subtotal,
    discount: discount,
    discountPercent: discountPercent,
    byRate: byRate,
  );
}

/// Details printed when a sale is given as an invoice (factuur) on the
/// receipt printer. The number comes from Supabase, so the laptop and the
/// iPad never use the same one.
class InvoiceInfo {
  final String number;
  final String customerName;
  final String customerAddress;
  final String customerVat;

  /// True when paid at the counter; false when the customer pays by
  /// bank transfer ("op rekening").
  final bool paid;

  const InvoiceInfo({
    required this.number,
    required this.customerName,
    this.customerAddress = '',
    this.customerVat = '',
    this.paid = true,
  });
}

/// Amount excluding VAT per rate, from [SaleTotals.byRate] (VAT included).
Map<int, int> exVatByRate(SaleTotals t) {
  final vat = t.vatByRate;
  return {for (final e in t.byRate.entries) e.key: e.value - (vat[e.key] ?? 0)};
}
