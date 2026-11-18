import 'dart:convert';
import 'dart:js_interop';
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

/// Starts a browser download of [bytes] as [fileName]. Returns the file name.
Future<String?> saveFileAs(String fileName, Uint8List bytes) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(
        type: 'application/vnd.openxmlformats-officedocument'
            '.spreadsheetml.sheet'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName;
  web.document.body!.appendChild(a);
  a.click();
  a.remove();
  // Give Safari time to start the download before releasing the blob.
  Future.delayed(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  return fileName;
}
