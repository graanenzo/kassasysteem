/// Writes the current product list as an .xlsx in the same column layout as
/// the PLU export, so it can be edited in Excel and read back with
/// "PLU inlezen".
///
/// Columns (0-based), matching plu_import.dart:
///   0  PLU number
///   1  name
///   2  description / second line
///   3  P = price per kg (weighed), C = price per piece
///   4  price in cents
///   17 EAN barcode
/// Columns 5–16 of the original export are not kept by the app and stay empty.
library;

import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'models.dart';

const pluExportHeader = <int, String>{
  0: 'PLU',
  1: 'Naam',
  2: 'Omschrijving',
  3: 'P=per kg, C=per stuk',
  4: 'Prijs (centen)',
  17: 'EAN',
};

Uint8List exportPluXlsx(List<Product> products) {
  final excel = Excel.createExcel();
  final sheet = excel[excel.getDefaultSheet()!];

  sheet.appendRow([
    for (var i = 0; i <= 17; i++) TextCellValue(pluExportHeader[i] ?? ''),
  ]);
  for (final p in products) {
    sheet.appendRow([
      IntCellValue(p.plu),
      TextCellValue(p.name),
      TextCellValue(p.description),
      TextCellValue(p.unit == SaleUnit.kg ? 'P' : 'C'),
      IntCellValue(p.priceCents),
      for (var i = 5; i <= 16; i++) null,
      // Text, so Excel does not turn long barcodes into 4,01553E+12.
      TextCellValue(p.ean),
    ]);
  }

  sheet.setColumnWidth(1, 32);
  sheet.setColumnWidth(2, 28);
  sheet.setColumnWidth(3, 20);
  sheet.setColumnWidth(4, 14);
  sheet.setColumnWidth(17, 16);

  return Uint8List.fromList(excel.encode()!);
}

String pluExportFileName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return 'PLU_export_${now.year}-${two(now.month)}-${two(now.day)}.xlsx';
}
