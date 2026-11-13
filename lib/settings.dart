/// Shop settings (receipt header/footer, printer) and the sales log.
library;

import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'product_store.dart';

class Settings {
  String shopName;
  String address; // multiple lines allowed
  String footer;
  String? printerUrl;
  String? printerName;
  int nextReceiptNo;

  Settings({
    this.shopName = 'Mijn Winkel',
    this.address = '',
    this.footer = 'Bedankt voor uw bezoek!',
    this.printerUrl,
    this.printerName,
    this.nextReceiptNo = 1,
  });

  Map<String, dynamic> toJson() => {
        'shopName': shopName,
        'address': address,
        'footer': footer,
        'printerUrl': printerUrl,
        'printerName': printerName,
        'nextReceiptNo': nextReceiptNo,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        shopName: (j['shopName'] ?? 'Mijn Winkel') as String,
        address: (j['address'] ?? '') as String,
        footer: (j['footer'] ?? '') as String,
        printerUrl: j['printerUrl'] as String?,
        printerName: j['printerName'] as String?,
        nextReceiptNo: (j['nextReceiptNo'] ?? 1) as int,
      );

  static Future<Settings> load() async {
    final f = await appFile('settings.json');
    if (!await f.exists()) return Settings();
    return Settings.fromJson(
        jsonDecode(await f.readAsString()) as Map<String, dynamic>);
  }

  Future<void> save() async {
    final f = await appFile('settings.json');
    await f.writeAsString(jsonEncode(toJson()));
  }
}

/// Append-only log of completed sales (one JSON object per line).
class SalesLog {
  static Future<void> append({
    required int receiptNo,
    required DateTime time,
    required String method,
    required List<CartLine> lines,
  }) async {
    final f = await appFile('sales.jsonl');
    final entry = {
      'no': receiptNo,
      'time': time.toIso8601String(),
      'method': method,
      'total': lines.fold<int>(0, (s, l) => s + l.totalCents),
      'lines': [
        for (final l in lines)
          {
            'plu': l.product.plu,
            'name': l.product.displayName,
            'qty': l.quantity,
            'grams': l.grams,
            'total': l.totalCents,
          }
      ],
    };
    await f.writeAsString('${jsonEncode(entry)}\n', mode: FileMode.append);
  }

  static Future<int> todayTotal() async {
    final f = await appFile('sales.jsonl');
    if (!await f.exists()) return 0;
    final now = DateTime.now();
    var sum = 0;
    for (final line in await f.readAsLines()) {
      if (line.trim().isEmpty) continue;
      final j = jsonDecode(line) as Map<String, dynamic>;
      final t = DateTime.parse(j['time'] as String);
      if (t.year == now.year && t.month == now.month && t.day == now.day) {
        sum += j['total'] as int;
      }
    }
    return sum;
  }
}
