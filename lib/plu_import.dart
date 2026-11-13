/// Reads the PLU export (B_PLU.CSV, or the same data saved as .xlsx).
///
/// Column layout of the export (0-based):
///   0  PLU number
///   1  name
///   2  description / second line
///   3  P = price per kg (weighed), C = price per piece
///   4  price in cents
///   17 EAN barcode (empty if none)
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

import 'models.dart';

class PluImportResult {
  final List<Product> products;
  final int skippedRows;
  const PluImportResult(this.products, this.skippedRows);

  int get withEan => products.where((p) => p.ean.isNotEmpty).length;
  int get weighed => products.where((p) => p.unit == SaleUnit.kg).length;
}

PluImportResult importPluFile(Uint8List bytes, String fileName) {
  final rows = fileName.toLowerCase().endsWith('.xlsx')
      ? _xlsxRows(bytes)
      : _csvRows(bytes);
  return parsePluRows(rows);
}

PluImportResult parsePluRows(List<List<String>> rows) {
  final products = <Product>[];
  var skipped = 0;
  for (final r in rows) {
    if (r.length < 5) {
      skipped++;
      continue;
    }
    final plu = int.tryParse(r[0].trim());
    final price = int.tryParse(r[4].trim());
    final name = r[1].trim();
    if (plu == null || price == null || name.isEmpty) {
      skipped++; // header or empty row
      continue;
    }
    final type = r[3].trim().toUpperCase();
    final ean = r.length > 17 ? r[17].replaceAll(RegExp(r'\D'), '') : '';
    products.add(Product(
      plu: plu,
      name: name,
      description: r[2].trim(),
      unit: type == 'P' ? SaleUnit.kg : SaleUnit.piece,
      priceCents: price,
      ean: ean,
    ));
  }
  return PluImportResult(products, skipped);
}

List<List<String>> _xlsxRows(Uint8List bytes) {
  final excel = Excel.decodeBytes(bytes);
  final sheet = excel.tables.values.first;
  return [
    for (final row in sheet.rows) [for (final c in row) _cellText(c?.value)]
  ];
}

String _cellText(CellValue? v) {
  if (v == null) return '';
  if (v is IntCellValue) return v.value.toString();
  if (v is DoubleCellValue) {
    final d = v.value;
    // Large barcodes can come in as doubles: avoid "2000063015209.0".
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toString();
  }
  return v.toString();
}

List<List<String>> _csvRows(Uint8List bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    text = latin1.decode(bytes); // older Windows exports
  }
  text = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final firstLine = text.split('\n').first;
  // Pick the delimiter that occurs most in the first line.
  var delimiter = ';';
  var best = -1;
  for (final d in const [';', '\t', ',']) {
    final n = d.allMatches(firstLine).length;
    if (n > best) {
      best = n;
      delimiter = d;
    }
  }
  final rows = CsvToListConverter(
    fieldDelimiter: delimiter,
    eol: '\n',
    shouldParseNumbers: false,
  ).convert(text);
  return [
    for (final r in rows) [for (final c in r) c.toString()]
  ];
}
