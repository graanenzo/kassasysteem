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

  Product copyWith({String? ean}) => Product(
        plu: plu,
        name: name,
        description: description,
        unit: unit,
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
