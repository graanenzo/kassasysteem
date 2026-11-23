/// Shop settings (receipt header/footer, printer) and the sales log.
library;

import 'dart:convert';

import 'models.dart';
import 'storage.dart';

/// Address of the shop's Epson receipt printer, used when none is set.
const defaultPrinterIp = '192.168.15.82';

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

  // Printed on an invoice (factuur) from the receipt printer.
  String invoiceName;
  String invoiceAddress;
  String vatNumber;
  String kvkNumber;
  String iban;
  int paymentDays;

  Settings({
    this.shopName = 'Mijn Winkel',
    this.address = '',
    this.footer = 'Bedankt voor uw bezoek!',
    this.printerUrl,
    this.printerName,
    this.printerIp = defaultPrinterIp,
    this.receiptWidth = 33,
    this.nextReceiptNo = 1,
    this.invoiceName = 'Graan & Zo B.V.',
    this.invoiceAddress = 'Oosteinde 7\n2969 AS Oud-Alblas',
    this.vatNumber = 'NL858035091B01',
    this.kvkNumber = '69843090',
    this.iban = 'NL83RABO0324067704',
    this.paymentDays = 7,
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
        'invoiceName': invoiceName,
        'invoiceAddress': invoiceAddress,
        'vatNumber': vatNumber,
        'kvkNumber': kvkNumber,
        'iban': iban,
        'paymentDays': paymentDays,
      };

  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        shopName: (j['shopName'] ?? 'Mijn Winkel') as String,
        address: (j['address'] ?? '') as String,
        footer: (j['footer'] ?? '') as String,
        printerUrl: j['printerUrl'] as String?,
        printerName: j['printerName'] as String?,
        printerIp: ((j['printerIp'] as String?)?.trim().isNotEmpty ?? false)
            ? j['printerIp'] as String
            : defaultPrinterIp,
        receiptWidth: (j['receiptWidth'] ?? 33) as int,
        nextReceiptNo: (j['nextReceiptNo'] ?? 1) as int,
        invoiceName: (j['invoiceName'] ?? 'Graan & Zo B.V.') as String,
        invoiceAddress:
            (j['invoiceAddress'] ?? 'Oosteinde 7\n2969 AS Oud-Alblas') as String,
        vatNumber: (j['vatNumber'] ?? 'NL858035091B01') as String,
        kvkNumber: (j['kvkNumber'] ?? '69843090') as String,
        iban: (j['iban'] ?? 'NL83RABO0324067704') as String,
        paymentDays: (j['paymentDays'] ?? 7) as int,
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
    int discountPercent = 0,
    String? invoiceNumber,
  }) async {
    final t = saleTotals(lines, discountPercent: discountPercent);
    final entry = {
      'no': receiptNo,
      'time': time.toIso8601String(),
      'method': method,
      if (invoiceNumber != null) 'invoice': invoiceNumber,
      'total': t.total,
      if (t.discount > 0) ...{
        'subtotal': t.subtotal,
        'discount': t.discount,
        'discount_percent': t.discountPercent,
      },
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

  /// Marks the sale with [receiptNo] as reopened: it stays in the log for
  /// reference but no longer counts. The corrected sale is logged again
  /// with a new receipt number when it is paid.
  static Future<void> markReopened(int receiptNo) async {
    final text = await readText('sales.jsonl');
    if (text == null) return;
    final lines = const LineSplitter().convert(text);
    // The most recent entry with this number is the one to reopen.
    for (var i = lines.length - 1; i >= 0; i--) {
      if (lines[i].trim().isEmpty) continue;
      final j = jsonDecode(lines[i]) as Map<String, dynamic>;
      if (j['no'] == receiptNo && j['reopened'] != true) {
        j['reopened'] = true;
        j['reopened_at'] = DateTime.now().toIso8601String();
        lines[i] = jsonEncode(j);
        break;
      }
    }
    await writeText('sales.jsonl',
        lines.where((l) => l.trim().isNotEmpty).map((l) => '$l\n').join());
  }

  static Future<int> todayTotal() async {
    final text = await readText('sales.jsonl');
    if (text == null) return 0;
    final now = DateTime.now();
    var sum = 0;
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      final j = jsonDecode(line) as Map<String, dynamic>;
      if (j['reopened'] == true) continue;
      final t = DateTime.parse(j['time'] as String);
      if (t.year == now.year && t.month == now.month && t.day == now.day) {
        sum += j['total'] as int;
      }
    }
    return sum;
  }
}
