import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

Future<File> _file(String name) async {
  final dir = await getApplicationSupportDirectory();
  await dir.create(recursive: true);
  return File('${dir.path}${Platform.pathSeparator}$name');
}

Future<String?> readText(String name) async {
  final f = await _file(name);
  return await f.exists() ? f.readAsString() : null;
}

Future<void> writeText(String name, String content) async =>
    (await _file(name)).writeAsString(content);

Future<void> appendText(String name, String content) async =>
    (await _file(name)).writeAsString(content, mode: FileMode.append);

Future<Uint8List?> readBytes(String name) async {
  final f = await _file(name);
  return await f.exists() ? f.readAsBytes() : null;
}

Future<void> writeBytes(String name, Uint8List bytes) async =>
    (await _file(name)).writeAsBytes(bytes);

Future<void> deleteStored(String name) async {
  final f = await _file(name);
  if (await f.exists()) await f.delete();
}

/// Reads a file picked with file_picker when only its path is known.
Future<Uint8List> readPickedPath(String path) => File(path).readAsBytes();

/// Asks where to save [bytes] and writes the file there. Returns the chosen
/// path, or null if the user cancelled.
Future<String?> saveFileAs(String fileName, Uint8List bytes) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'PLU-lijst opslaan',
    fileName: fileName,
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
  );
  if (path == null) return null;
  final target = path.toLowerCase().endsWith('.xlsx') ? path : '$path.xlsx';
  await File(target).writeAsBytes(bytes);
  return target;
}
