/// Full on-screen keyboard (letters and digits) for the search field. On an
/// iPad with a scanner attached the system keyboard stays hidden.
library;

import 'package:flutter/material.dart';

class OnScreenKeyboard extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onEnter;
  final VoidCallback onClose;

  const OnScreenKeyboard({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onEnter,
    required this.onClose,
  });

  void _set(String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged();
  }

  Widget _key(String label, VoidCallback onTap,
      {int flex = 2, bool action = false}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: 52,
          child: action
              ? OutlinedButton(
                  onPressed: onTap,
                  child: Text(label, style: const TextStyle(fontSize: 18)),
                )
              : FilledButton.tonal(
                  onPressed: onTap,
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                  child: Text(label, style: const TextStyle(fontSize: 22)),
                ),
        ),
      ),
    );
  }

  Widget _row(String keys, {int indent = 0, List<Widget> trailing = const []}) {
    return Row(children: [
      if (indent > 0) Spacer(flex: indent),
      for (final k in keys.split(''))
        _key(k.toUpperCase(), () => _set(controller.text + k)),
      ...trailing,
      if (indent > 0) Spacer(flex: indent),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = controller.text;
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _row('1234567890'),
            _row('qwertyuiop'),
            _row('asdfghjkl', indent: 1),
            _row('zxcvbnm', indent: 0, trailing: [
              _key('⌫', () {
                if (t.isNotEmpty) _set(t.substring(0, t.length - 1));
              }, flex: 3, action: true),
            ]),
            Row(children: [
              _key('Sluiten', onClose, flex: 4, action: true),
              _key('Wissen', () => _set(''), flex: 3, action: true),
              _key('spatie', () => _set('$t '), flex: 8),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: onEnter,
                      child: const Text('Enter',
                          style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
