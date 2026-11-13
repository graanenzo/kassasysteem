/// Prints receipts directly on an Epson network receipt printer (ESC/POS,
/// raw TCP port 9100). Made for the Epson TM-U220 (impact, 76 mm paper),
/// works on most Epson TM printers.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;

import 'models.dart';
import 'product_store.dart' show appFile;
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

  /// Prints [src] as an 8-dot double-density bit image (ESC *), which
  /// 9-pin impact printers like the TM-U220 support. Double density has
  /// twice the horizontal resolution, so the image is squashed vertically
  /// by half to keep its proportions.
  void image(img.Image src, {int maxDots = 180}) {
    final w = (src.width * 2).clamp(8, maxDots);
    final rows = (src.height * w / src.width / 2).round().clamp(1, 400);
    final r = img.copyResize(src,
        width: w, height: rows, interpolation: img.Interpolation.average);

    bool dark(int x, int y) {
      final p = r.getPixel(x, y);
      final lum =
          0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized;
      // Anything clearly darker than white prints, so coloured parts of a
      // logo (like a yellow '&') are not lost.
      return p.aNormalized > 0.5 && lum < 0.8;
    }

    _bytes.addAll([_esc, 0x33, 16]); // line spacing = one 8-dot band
    for (var y = 0; y < rows; y += 8) {
      _bytes.addAll([_esc, 0x2A, 1, w & 0xFF, w >> 8]);
      for (var x = 0; x < w; x++) {
        var b = 0;
        for (var bit = 0; bit < 8; bit++) {
          final yy = y + bit;
          if (yy < rows && dark(x, yy)) b |= 0x80 >> bit;
        }
        _bytes.add(b);
      }
      _bytes.add(0x0A);
    }
    _bytes.addAll([_esc, 0x32]); // default line spacing
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
  img.Image? logo,
}) {
  final p = EscPosBuilder(settings.receiptWidth);
  final total = lines.fold<int>(0, (s, l) => s + l.totalCents);

  p.align(1);
  if (logo != null) {
    p.image(logo);
    p.feed(1); // space between logo and date
  }
  if (settings.address.trim().isNotEmpty) p.text(settings.address.trim());
  p.text(formatDateTime(time));
  p.align(0);
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
  p.cut(); // GS V 66 already feeds the last line past the cutter
  return p.bytes;
}

List<int> buildEscPosTest(Settings settings, {img.Image? logo}) {
  final p = EscPosBuilder(settings.receiptWidth);
  p.align(1);
  if (logo != null) p.image(logo);
  p.bold(true);
  p.text('TESTBON');
  p.bold(false);
  p.align(0);
  p.text('1234567890' * 10);
  p.text('^ ${settings.receiptWidth} tekens per regel ingesteld');
  p.row('Links', 'rechts');
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

/// The receipt logo: a logo chosen in the settings (logo.png in the app
/// folder), otherwise the built-in Graan & Zo logo.
Future<img.Image?> loadLogo() async {
  final f = await appFile('logo.png');
  if (await f.exists()) return img.decodeImage(await f.readAsBytes());
  try {
    final data = await rootBundle.load('assets/logo.png');
    return img.decodeImage(data.buffer.asUint8List());
  } catch (_) {
    return null;
  }
}

/// Saves a chosen image as the receipt logo. Returns false if the file
/// is not a readable image.
Future<bool> saveLogo(Uint8List bytes) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return false;
  final f = await appFile('logo.png');
  await f.writeAsBytes(img.encodePng(decoded));
  return true;
}

Future<void> removeLogo() async {
  final f = await appFile('logo.png');
  if (await f.exists()) await f.delete();
}
