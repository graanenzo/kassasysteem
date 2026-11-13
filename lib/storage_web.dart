import 'dart:convert';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _prefix = 'kassa_';

Future<String?> readText(String name) async =>
    web.window.localStorage.getItem('$_prefix$name');

Future<void> writeText(String name, String content) async =>
    web.window.localStorage.setItem('$_prefix$name', content);

Future<void> appendText(String name, String content) async {
  final old = await readText(name) ?? '';
  await writeText(name, old + content);
}

Future<Uint8List?> readBytes(String name) async {
  final s = await readText(name);
  return s == null ? null : base64Decode(s);
}

Future<void> writeBytes(String name, Uint8List bytes) =>
    writeText(name, base64Encode(bytes));

Future<void> deleteStored(String name) async =>
    web.window.localStorage.removeItem('$_prefix$name');

Future<Uint8List> readPickedPath(String path) =>
    throw UnsupportedError('Op het web komt het bestand altijd als bytes');
