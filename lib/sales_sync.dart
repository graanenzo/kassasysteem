/// Sends sales to the database (Supabase), so stock and "last sold" are
/// known centrally. Every sale first goes into a queue on this device and
/// is sent from there: without internet the till keeps working and the
/// queue is sent later. Each sale has its own id, so sending twice never
/// books it twice.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'storage.dart';

const _supabaseUrl = 'https://gxlbqxdloucaisnxmpky.supabase.co';
const _publishableKey = 'sb_publishable_1GtIrj9YZq1nuI206Fztfg_cod8_0e1';
const _queueFile = 'sales_queue.json';

/// Random UUID (version 4) for a sale.
String newSaleId() {
  final r = Random.secure();
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// The sale as the database function kassa_verkoop_boeken wants it.
/// Weighed lines are in kg with the price per kg.
Map<String, dynamic> salePayload({
  required String id,
  required DateTime time,
  required int receiptNo,
  required String method,
  required List<CartLine> lines,
  required int discountPercent,
  String? invoiceNumber,
}) {
  final t = saleTotals(lines, discountPercent: discountPercent);
  return {
    'id': id,
    'tijd': time.toUtc().toIso8601String(),
    'kassa': kIsWeb ? 'iPad (web)' : 'laptop',
    'methode': method,
    'bonnummer': receiptNo,
    'factuurnummer': invoiceNumber,
    'korting_pct': discountPercent,
    'totaal': t.total / 100,
    'regels': [
      for (var i = 0; i < lines.length; i++)
        {
          'regel': i + 1,
          'plu': lines[i].product.plu,
          'ean': lines[i].product.ean,
          'omschrijving': lines[i].product.displayName,
          'aantal': lines[i].grams != null
              ? lines[i].grams! * lines[i].quantity / 1000
              : lines[i].quantity,
          'gram': lines[i].grams,
          'prijs': lines[i].grams != null
              ? lines[i].product.priceCents / 100
              : lines[i].unitPriceCents / 100,
          'bedrag': lines[i].totalCents / 100,
        }
    ],
  };
}

class SalesSync {
  static bool _busy = false;

  static Future<List<Map<String, dynamic>>> _read() async {
    final text = await readText(_queueFile);
    if (text == null || text.trim().isEmpty) return [];
    return [
      for (final e in jsonDecode(text) as List) Map<String, dynamic>.from(e as Map)
    ];
  }

  static Future<void> _write(List<Map<String, dynamic>> q) =>
      writeText(_queueFile, jsonEncode(q));

  /// Number of sales (and reopen messages) still waiting to be sent.
  static Future<int> pending() async => (await _read()).length;

  /// Queues a sale and tries to send the queue.
  static Future<void> add(Map<String, dynamic> sale) async {
    final q = await _read();
    q.add({'type': 'verkoop', 'p': sale});
    await _write(q);
    send();
  }

  /// Queues "this sale was reopened" (stock goes back in the database).
  static Future<void> reopened(String saleId) async {
    final q = await _read();
    q.add({'type': 'heropend', 'id': saleId});
    await _write(q);
    send();
  }

  /// Sends the queue in order; stops at the first failure (offline) and
  /// tries again next time.
  static Future<void> send() async {
    if (_busy) return;
    _busy = true;
    try {
      var q = await _read();
      while (q.isNotEmpty) {
        final e = q.first;
        final ok = e['type'] == 'heropend'
            ? await _rpc('kassa_verkoop_heropenen', {'p_id': e['id']})
            : await _rpc('kassa_verkoop_boeken', {'p': e['p']});
        if (!ok) break;
        // Re-read: a sale may have been added while sending.
        q = await _read();
        if (q.isNotEmpty && jsonEncode(q.first) == jsonEncode(e)) {
          q.removeAt(0);
          await _write(q);
        }
      }
    } finally {
      _busy = false;
    }
  }

  static Future<bool> _rpc(String name, Map<String, dynamic> body) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_supabaseUrl/rest/v1/rpc/$name'),
            headers: {
              'apikey': _publishableKey,
              'Authorization': 'Bearer $_publishableKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 15));
      return res.statusCode == 200 || res.statusCode == 204;
    } catch (_) {
      return false;
    }
  }
}
