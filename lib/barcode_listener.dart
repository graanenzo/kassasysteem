/// Picks up scans from a USB barcode scanner.
///
/// A USB scanner behaves like a keyboard: it types the digits very fast and
/// ends with Enter. A human types much slower, so keys more than [maxGap]
/// apart start a new buffer.
library;

import 'package:flutter/services.dart';

class BarcodeListener {
  final void Function(String code) onScan;
  final bool Function() isActive;
  final Duration maxGap;
  final int minLength;

  final _buffer = StringBuffer();
  DateTime _lastKey = DateTime.fromMillisecondsSinceEpoch(0);

  BarcodeListener({
    required this.onScan,
    required this.isActive,
    this.maxGap = const Duration(milliseconds: 60),
    this.minLength = 8,
  }) {
    HardwareKeyboard.instance.addHandler(_handle);
  }

  bool _handle(KeyEvent e) {
    if (e is! KeyDownEvent) return false;
    final now = DateTime.now();
    if (now.difference(_lastKey) > maxGap) _buffer.clear();
    _lastKey = now;

    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final code = _buffer.toString();
      _buffer.clear();
      if (code.length >= minLength && isActive()) {
        onScan(code);
        return true; // swallow Enter so text fields don't also submit
      }
      return false;
    }
    final ch = e.character;
    if (ch != null && ch.length == 1 && RegExp(r'\d').hasMatch(ch)) {
      _buffer.write(ch);
    }
    return false;
  }

  void dispose() => HardwareKeyboard.instance.removeHandler(_handle);
}
