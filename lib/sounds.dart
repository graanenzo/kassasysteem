/// Scan feedback beeps: a short high blip when a product is added and a
/// low double tone when a code is not recognised.
library;

export 'sounds_io.dart' if (dart.library.js_interop) 'sounds_web.dart';
