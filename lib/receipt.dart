/// Builds the receipt as an 80 mm roll PDF and prints it.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'models.dart';
import 'settings.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String formatDateTime(DateTime t) =>
    '${_two(t.day)}-${_two(t.month)}-${t.year} ${_two(t.hour)}:${_two(t.minute)}';

String lineDetail(CartLine l) {
  if (l.grams != null) {
    final kg = (l.grams! / 1000).toStringAsFixed(3).replaceAll('.', ',');
    final q = l.quantity > 1 ? '${l.quantity} x ' : '';
    return '$q$kg kg x ${money(l.product.priceCents)}/kg';
  }
  return '${l.quantity} x ${money(l.unitPriceCents)}';
}

Future<Uint8List> buildReceipt({
  required Settings settings,
  required List<CartLine> lines,
  required int receiptNo,
  required DateTime time,
}) async {
  // Courier is built in (no internet needed). Built-in PDF fonts cannot
  // print the euro sign, so amounts are shown in EUR without symbol.
  final font = pw.Font.courier();
  final bold = pw.Font.courierBold();
  final s = pw.TextStyle(font: font, fontSize: 9);
  final big = pw.TextStyle(font: bold, fontSize: 12);

  final total = lines.fold<int>(0, (sum, l) => sum + l.totalCents);

  // VAT included in prices, grouped per rate.
  final byRate = <int, int>{};
  for (final l in lines) {
    byRate.update(l.product.vatPercent, (v) => v + l.totalCents,
        ifAbsent: () => l.totalCents);
  }

  pw.Widget row(String left, String right, [pw.TextStyle? style]) => pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Expanded(child: pw.Text(left, style: style ?? s)),
          pw.SizedBox(width: 6),
          pw.Text(right, style: style ?? s),
        ],
      );
  pw.Widget divider() => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 3),
        child: pw.Divider(thickness: 0.5, height: 1),
      );

  final doc = pw.Document();
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.roll80,
    build: (ctx) => pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Text(settings.shopName,
            style: big, textAlign: pw.TextAlign.center),
        if (settings.address.trim().isNotEmpty)
          pw.Text(settings.address.trim(),
              style: s, textAlign: pw.TextAlign.center),
        pw.SizedBox(height: 4),
        row('Bon $receiptNo', formatDateTime(time)),
        divider(),
        for (final l in lines) ...[
          pw.Text(l.product.displayName, style: s),
          row('  ${lineDetail(l)}', money(l.totalCents)),
        ],
        divider(),
        row('TOTAAL EUR', money(total), big),
        divider(),
        for (final e in byRate.entries)
          row('Waarvan btw ${e.key}%',
              money((e.value * e.key / (100 + e.key)).round())),
        pw.SizedBox(height: 6),
        if (settings.footer.trim().isNotEmpty)
          pw.Text(settings.footer.trim(),
              style: s, textAlign: pw.TextAlign.center),
      ],
    ),
  ));
  return doc.save();
}

/// Prints directly to the chosen receipt printer, or shows the print dialog
/// when no printer was chosen (or direct printing fails).
Future<void> printReceipt(Uint8List pdf, Settings settings) async {
  final url = settings.printerUrl;
  if (url != null) {
    try {
      final ok = await Printing.directPrintPdf(
        printer: Printer(url: url, name: settings.printerName),
        onLayout: (_) async => pdf,
        name: 'Bon',
      );
      if (ok) return;
    } catch (_) {
      // fall through to the dialog
    }
  }
  await Printing.layoutPdf(onLayout: (_) async => pdf, name: 'Bon');
}
