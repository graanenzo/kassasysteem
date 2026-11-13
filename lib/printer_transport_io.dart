import 'dart:io';

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
