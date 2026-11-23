import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kassasysteem/onscreen_keyboard.dart';

void main() {
  Future<TextEditingController> pump(WidgetTester t, {bool autoCap = false}) async {
    final c = TextEditingController();
    await t.binding.setSurfaceSize(const Size(1200, 900));
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: OnScreenKeyboard(
            controller: c,
            autoCapitalize: autoCap,
            onChanged: () {},
            onEnter: () {},
            onClose: () {},
          ),
        ),
      ),
    ));
    return c;
  }

  Future<void> tap(WidgetTester t, String label) async {
    await t.tap(find.text(label).first);
    await t.pump();
  }

  testWidgets('standaard kleine letters, ⇧ maakt één hoofdletter', (t) async {
    final c = await pump(t);
    await tap(t, 'a');
    await tap(t, '⇧');
    await tap(t, 'B');
    await tap(t, 'c');
    expect(c.text, 'aBc');
  });

  testWidgets('⇧ lang indrukken = hoofdletters vast', (t) async {
    final c = await pump(t);
    await t.longPress(find.text('⇧'));
    await t.pump();
    await tap(t, 'N');
    await tap(t, 'L');
    expect(c.text, 'NL');
    await tap(t, '⇪');
    await tap(t, 'x');
    expect(c.text, 'NLx');
  });

  testWidgets('autoCapitalize: elk woord begint met een hoofdletter', (t) async {
    final c = await pump(t, autoCap: true);
    for (final k in ['P', 'u', 'u', 'r', 'spatie', 'E', 'n']) {
      await tap(t, k);
    }
    expect(c.text, 'Puur En');
  });
}
