/// Builds the receipt as an 80 mm roll PDF and prints it.
library;

import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'models.dart';
import 'settings.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String formatDate(DateTime t) => '${_two(t.day)}-${_two(t.month)}-${t.year}';
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
  int discountPercent = 0,
  InvoiceInfo? invoice,
}) async {
  // Courier is built in (no internet needed). Built-in PDF fonts cannot
  // print the euro sign, so amounts are shown in EUR without symbol.
  final font = pw.Font.courier();
  final bold = pw.Font.courierBold();
  final s = pw.TextStyle(font: font, fontSize: 9);
  final big = pw.TextStyle(font: bold, fontSize: 12);

  final t = saleTotals(lines, discountPercent: discountPercent);

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
        if (invoice != null) ...[
          pw.Text('FACTUUR', style: big, textAlign: pw.TextAlign.center),
          divider(),
          pw.Text(settings.invoiceName.trim(), style: s),
          if (settings.invoiceAddress.trim().isNotEmpty)
            pw.Text(settings.invoiceAddress.trim(), style: s),
          if (settings.vatNumber.trim().isNotEmpty)
            row('BTW', settings.vatNumber.trim()),
          if (settings.kvkNumber.trim().isNotEmpty)
            row('KVK', settings.kvkNumber.trim()),
          if (settings.iban.trim().isNotEmpty) row('Bank', settings.iban.trim()),
          divider(),
          row('Factuurnummer', invoice.number, pw.TextStyle(font: bold, fontSize: 9)),
          row('Factuurdatum', formatDate(time)),
          row('Leverdatum', formatDate(time)),
          row('Bon', '$receiptNo'),
          divider(),
          pw.Text('Aan:', style: pw.TextStyle(font: bold, fontSize: 9)),
          pw.Text(invoice.customerName.trim(), style: s),
          if (invoice.customerAddress.trim().isNotEmpty)
            pw.Text(invoice.customerAddress.trim(), style: s),
          if (invoice.customerVat.trim().isNotEmpty)
            row('BTW', invoice.customerVat.trim()),
        ] else ...[
          pw.Text(settings.shopName,
              style: big, textAlign: pw.TextAlign.center),
          if (settings.address.trim().isNotEmpty)
            pw.Text(settings.address.trim(),
                style: s, textAlign: pw.TextAlign.center),
          pw.SizedBox(height: 4),
          row('Bon $receiptNo', formatDateTime(time)),
        ],
        divider(),
        for (final l in lines) ...[
          pw.Text(l.product.displayName, style: s),
          row(invoice != null
                  ? '  ${lineDetail(l)} (${l.product.vatPercent}%)'
                  : '  ${lineDetail(l)}',
              money(l.totalCents)),
        ],
        divider(),
        if (t.discount > 0) ...[
          row('Subtotaal', money(t.subtotal)),
          row('Personeelskorting ${t.discountPercent}%', money(-t.discount)),
        ],
        if (invoice != null) ...[
          for (final r in (t.byRate.keys.toList()..sort()))
            row('Excl. btw $r%', money(exVatByRate(t)[r]!)),
          for (final r in (t.byRate.keys.toList()..sort()))
            row('Btw $r%', money(t.vatByRate[r]!)),
        ],
        row('TOTAAL EUR', money(t.total), big),
        divider(),
        if (invoice == null)
          for (final e in t.vatByRate.entries)
            row('Waarvan btw ${e.key}%', money(e.value))
        else if (invoice.paid)
          pw.Text('Voldaan op ${formatDate(time)}.', style: s)
        else
          pw.Text(
              'Wij verzoeken u het bedrag van EUR ${money(t.total)} binnen '
              '${settings.paymentDays} dagen over te maken op '
              '${settings.iban.trim()} t.n.v. ${settings.invoiceName.trim()}, '
              'o.v.v. ${invoice.number}.',
              style: s),
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
