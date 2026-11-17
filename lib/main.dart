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
        useMaterial3: true,
        // Graan & Zo: black with the gold of the '&' in the logo.
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFFE8AC00))
            .copyWith(
          primary: const Color(0xFF1A1A1A),
          onPrimary: Colors.white,
          secondaryContainer: const Color(0xFFFFE6A3),
          onSecondaryContainer: const Color(0xFF1A1A1A),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          elevation: 1,
        ),
      ),
      home: const PosScreen(),
    );
  }
}
