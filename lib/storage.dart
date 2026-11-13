/// Simple key/value file storage: files in the app folder on desktop,
/// browser localStorage on the web.
library;

export 'storage_io.dart' if (dart.library.js_interop) 'storage_web.dart';
