/// Shop settings (receipt header/footer, printer) and the sales log.
library;

import 'dart:convert';

import 'models.dart';
import 'storage.dart';

class Settings {
  String shopName;
  String address; // multiple lines allowed
  String footer;
  String? printerUrl;
  String? printerName;

  /// IP address of an Epson network receipt printer (ESC/POS). When set,
  /// receipts go straight to this printer instead of via Windows printing.
  String printerIp;

  /// Characters per line on the receipt printer.
  int receiptWidth;
  int nextReceiptNo;

  Settings({
    this.shopName = 'Mijn Winkel',
    this.address = '',
    this.footer = 'Bedankt voor uw bezoek!',
    this.printerUrl,
    this.printerName,
    this.printerIp = '',
    this.receiptWidth = 33,
    this.nextReceiptNo = 1,
  });

  Map<String, dynamic> toJson() => {
        'shopName': shopName,
        'address': address,
        'footer': footer,
        'printerUrl': printerUrl,
        'printerName': printerName,
        'printerIp': printerIp,
        'receiptWidth': receiptWidth,
        'nextReceiptNo': nextReceiptNo,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        shopName: (j['shopName'] ?? 'Mijn Winkel') as String,
        address: (j['address'] ?? '') as String,
        footer: (j['footer'] ?? '') as String,
        printerUrl: j['printerUrl'] as String?,
        printerName: j['printerName'] as String?,
        printerIp: (j['printerIp'] ?? '') as String,
        receiptWidth: (j['receiptWidth'] ?? 33) as int,
        nextReceiptNo: (j['nextReceiptNo'] ?? 1) as int,
      );

  static Future<Settings> load() async {
    final text = await readText('settings.json');
    if (text == null) return Settings();
    return Settings.fromJson(jsonDecode(text) as Map<String, dynamic>);
  }

  Future<void> save() async {
    await writeText('settings.json', jsonEncode(toJson()));
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
    await appendText('sales.jsonl', '${jsonEncode(entry)}\n');
  }

  static Future<int> todayTotal() async {
    final text = await readText('sales.jsonl');
    if (text == null) return 0;
    final now = DateTime.now();
    var sum = 0;
    for (final line in const LineSplitter().convert(text)) {
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
