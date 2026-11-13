import 'package:http/http.dart' as http;

/// Browsers cannot open raw sockets, so the receipt goes through the
/// printer's ePOS-Print web service. The ESC/POS bytes are passed along
/// unchanged inside a <command> element.
Future<void> sendToNetworkPrinter(String ip, List<int> bytes) async {
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final body = '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
      '<s:Body>'
      '<epos-print xmlns="http://www.epson-pos.com/schemas/2011/03/epos-print">'
      '<command>$hex</command>'
      '</epos-print>'
      '</s:Body>'
      '</s:Envelope>';
  final uri = Uri.parse('https://${ip.trim()}/cgi-bin/epos/service.cgi'
      '?devid=local_printer&timeout=10000');
  final res = await http
      .post(uri,
          headers: {
            'Content-Type': 'text/xml; charset=utf-8',
            'SOAPAction': '""',
          },
          body: body)
      .timeout(const Duration(seconds: 15));
  if (res.statusCode != 200) {
    throw Exception('printer gaf status ${res.statusCode}');
  }
  if (!res.body.contains('success="true"')) {
    throw Exception('printer meldt fout: ${res.body}');
  }
}
