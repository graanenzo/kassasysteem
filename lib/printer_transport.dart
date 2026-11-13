/// Sends ESC/POS bytes to the network receipt printer: raw TCP port 9100
/// on desktop, Epson ePOS-Print (HTTPS) in the browser.
library;

export 'printer_transport_io.dart'
    if (dart.library.js_interop) 'printer_transport_web.dart';
