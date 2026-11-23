/// Gets the next invoice number from Supabase and stores the invoice there.
/// One counter for all tills (laptop and iPad), so a number is never used
/// twice. Numbers look like K2026-0001.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'models.dart';
import 'receipt.dart' show lineDetail;

const _supabaseUrl = 'https://gxlbqxdloucaisnxmpky.supabase.co';
const _publishableKey = 'sb_publishable_1GtIrj9YZq1nuI206Fztfg_cod8_0e1';

double _eur(int cents) => cents / 100;

/// Registers the invoice and returns its number. Throws with a readable
/// message when Supabase cannot be reached: without a number no invoice.
Future<String> createInvoice({
  required List<CartLine> lines,
  required int discountPercent,
  required int receiptNo,
  required String customerName,
  required String customerAddress,
  required String customerVat,
  required bool paid,
}) async {
  final t = saleTotals(lines, discountPercent: discountPercent);
  final vat = t.vatByRate;
  final ex = exVatByRate(t);
  final body = {
    'p': {
      'kassa': kIsWeb ? 'iPad (web)' : 'laptop',
      'bonnummer': receiptNo,
      'klant_naam': customerName,
      'klant_adres': customerAddress,
      'klant_btw': customerVat,
      'betaald': paid,
      'totaal': _eur(t.total),
      'btw': [
        for (final r in t.byRate.keys)
          {'tarief': r, 'excl': _eur(ex[r]!), 'btw': _eur(vat[r]!), 'incl': _eur(t.byRate[r]!)}
      ],
      'regels': [
        for (final l in lines)
          {
            'plu': l.product.plu,
            'naam': l.product.displayName,
            'aantal': l.quantity,
            'gram': l.grams,
            'detail': lineDetail(l),
            'prijs': _eur(l.unitPriceCents),
            'totaal': _eur(l.totalCents),
            'btw': l.product.vatPercent,
          }
      ],
      if (discountPercent > 0) 'korting_pct': discountPercent,
    }
  };
  final http.Response res;
  try {
    res = await http
        .post(
          Uri.parse('$_supabaseUrl/rest/v1/rpc/kassa_factuur_aanmaken'),
          headers: {
            'apikey': _publishableKey,
            'Authorization': 'Bearer $_publishableKey',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
  } catch (_) {
    throw Exception('Geen verbinding met de database. Zonder internet kan er '
        'geen factuurnummer worden uitgegeven; probeer het opnieuw.');
  }
  if (res.statusCode != 200) {
    var msg = 'status ${res.statusCode}';
    try {
      msg = (jsonDecode(utf8.decode(res.bodyBytes)) as Map)['message']?.toString() ?? msg;
    } catch (_) {}
    throw Exception('Factuurnummer ophalen mislukt: $msg');
  }
  return jsonDecode(utf8.decode(res.bodyBytes)) as String;
}
