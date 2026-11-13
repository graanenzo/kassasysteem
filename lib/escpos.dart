/// Prints receipts directly on an Epson network receipt printer (ESC/POS,
/// raw TCP port 9100). Made for the Epson TM-U220 (impact, 76 mm paper),
/// works on most Epson TM printers.
library;

import 'dart:io';

import 'models.dart';
import 'receipt.dart' show formatDateTime, lineDetail;
import 'settings.dart';

const _esc = 0x1B;
const _gs = 0x1D;

class EscPosBuilder {
  final int width;
  final _bytes = <int>[];

  EscPosBuilder(this.width) {
    _bytes.addAll([_esc, 0x40]); // initialize
  }

  /// Impact printers have no reliable accented characters / euro sign
  /// across code pages, so text is reduced to plain ASCII.
  static String ascii(String s) {
    const map = {
      'à': 'a', 'á': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a',
      'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
      'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
      'ò': 'o', 'ó': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o',
      'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
      'ç': 'c', 'ñ': 'n', 'ß': 'ss',
      'À': 'A', 'Á': 'A', 'Ä': 'A', 'È': 'E', 'É': 'E', 'Ë': 'E',
      'Ï': 'I', 'Ö': 'O', 'Ü': 'U', 'Ç': 'C', 'Ñ': 'N',
      '€': 'EUR', '‘': "'", '’': "'", '“': '"', '”': '"', '–': '-', '—': '-',
    };
    final b = StringBuffer();
    for (final ch in s.split('')) {
      final r = map[ch];
      if (r != null) {
        b.write(r);
      } else if (ch.codeUnitAt(0) < 128) {
        b.write(ch);
      } else {
        b.write('?');
      }
    }
    return b.toString();
  }

  void _write(String s) => _bytes.addAll(ascii(s).codeUnits);

  void align(int a) => _bytes.addAll([_esc, 0x61, a]); // 0 left, 1 center
  void bold(bool on) => _bytes.addAll([_esc, 0x45, on ? 1 : 0]);
  void doubleHeight(bool on) => _bytes.addAll([_esc, 0x21, on ? 0x10 : 0x00]);

  void text(String s) {
    for (final line in _wrap(s)) {
      _write(line);
      _bytes.add(0x0A);
    }
  }

  void row(String left, String right) {
    final space = width - right.length - 1;
    final lines = _wrap(left, space);
    for (var i = 0; i < lines.length; i++) {
      if (i == lines.length - 1) {
        _write(lines[i].padRight(space + 1) + right);
      } else {
        _write(lines[i]);
      }
      _bytes.add(0x0A);
    }
  }

  void divider() => text('-' * width);
  void feed(int lines) => _bytes.addAll([_esc, 0x64, lines]);

  /// Feeds paper to the cutter and cuts (ignored without autocutter).
  void cut() => _bytes.addAll([_gs, 0x56, 0x42, 0x00]);

  List<String> _wrap(String s, [int? w]) {
    final max = w ?? width;
    final out = <String>[];
    for (final para in s.split('\n')) {
      var line = '';
      for (final word in para.split(' ')) {
        if (word.isEmpty) continue;
        if (line.isEmpty) {
          line = word;
        } else if (line.length + 1 + word.length <= max) {
          line = '$line $word';
        } else {
          out.add(line);
          line = word;
        }
        while (line.length > max) {
          out.add(line.substring(0, max));
          line = line.substring(max);
        }
      }
      out.add(line);
    }
    return out;
  }

  List<int> get bytes => _bytes;
}

List<int> buildEscPosReceipt({
  required Settings settings,
  required List<CartLine> lines,
  required int receiptNo,
  required DateTime time,
}) {
  final p = EscPosBuilder(settings.receiptWidth);
  final total = lines.fold<int>(0, (s, l) => s + l.totalCents);

  p.align(1);
  p.bold(true);
  p.doubleHeight(true);
  p.text(settings.shopName);
  p.doubleHeight(false);
  p.bold(false);
  if (settings.address.trim().isNotEmpty) p.text(settings.address.trim());
  p.align(0);
  p.feed(1);
  p.row('Bon $receiptNo', formatDateTime(time));
  p.divider();
  for (final l in lines) {
    p.text(l.product.displayName);
    p.row('  ${lineDetail(l)}', money(l.totalCents));
  }
  p.divider();
  p.bold(true);
  p.doubleHeight(true);
  p.row('TOTAAL EUR', money(total));
  p.doubleHeight(false);
  p.bold(false);
  p.divider();

  final byRate = <int, int>{};
  for (final l in lines) {
    byRate.update(l.product.vatPercent, (v) => v + l.totalCents,
        ifAbsent: () => l.totalCents);
  }
  for (final e in byRate.entries) {
    p.row('Waarvan btw ${e.key}%',
        money((e.value * e.key / (100 + e.key)).round()));
  }
  if (settings.footer.trim().isNotEmpty) {
    p.feed(1);
    p.align(1);
    p.text(settings.footer.trim());
    p.align(0);
  }
  p.feed(2);
  p.cut();
  return p.bytes;
}

List<int> buildEscPosTest(Settings settings) {
  final p = EscPosBuilder(settings.receiptWidth);
  p.align(1);
  p.bold(true);
  p.text('TESTBON');
  p.bold(false);
  p.text(settings.shopName);
  p.align(0);
  p.text('1234567890' * 10);
  p.text('^ ${settings.receiptWidth} tekens per regel ingesteld');
  p.row('Links', 'rechts');
  p.feed(2);
  p.cut();
  return p.bytes;
}

/// Sends raw ESC/POS bytes to the printer on TCP port 9100.
Future<void> sendToNetworkPrinter(String ip, List<int> bytes) async {
  final socket = await Socket.connect(ip.trim(), 9100,
      timeout: const Duration(seconds: 5));
  try {
    socket.add(bytes);
    await socket.flush();
  } finally {
    await socket.close();
  }
}
