import 'package:flutter/material.dart';

import 'pos_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const KassaApp());
}

class KassaApp extends StatelessWidget {
  const KassaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Kassa',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF7A5230),
        useMaterial3: true,
      ),
      home: const PosScreen(),
    );
  }
}
