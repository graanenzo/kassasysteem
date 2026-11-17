/// On-screen number pad. On an iPad with a scanner attached the system
/// keyboard stays hidden, so number fields get their own keys.
library;

import 'package:flutter/material.dart';

class NumPad extends StatelessWidget {
  final TextEditingController controller;

  /// Called after every key, so the screen can react to the new value.
  final VoidCallback? onChanged;

  /// Shows a wide OK key that calls this.
  final VoidCallback? onEnter;
  final String enterLabel;

  /// Shows a comma key (for prices) instead of the clear key.
  final bool decimal;
  final double keyHeight;

  const NumPad({
    super.key,
    required this.controller,
    this.onChanged,
    this.onEnter,
    this.enterLabel = 'OK',
    this.decimal = false,
    this.keyHeight = 52,
  });

  void _set(String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged?.call();
  }

  void _press(String key) {
    final t = controller.text;
    switch (key) {
      case '⌫':
        if (t.isNotEmpty) _set(t.substring(0, t.length - 1));
      case 'C':
        _set('');
      case ',':
        if (!t.contains(',')) _set(t.isEmpty ? '0,' : '$t,');
      default:
        _set(t + key);
    }
  }

  Widget _key(BuildContext context, String label) {
    final isAction = label == '⌫' || label == 'C';
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: keyHeight,
          child: isAction
              ? OutlinedButton(
                  onPressed: () => _press(label),
                  child: Text(label, style: const TextStyle(fontSize: 22)),
                )
              : FilledButton.tonal(
                  onPressed: () => _press(label),
                  child: Text(label, style: const TextStyle(fontSize: 24)),
                ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = [
      ['7', '8', '9'],
      ['4', '5', '6'],
      ['1', '2', '3'],
      [decimal ? ',' : 'C', '0', '⌫'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final r in rows) Row(children: [for (final k in r) _key(context, k)]),
        if (onEnter != null)
          Padding(
            padding: const EdgeInsets.all(3),
            child: SizedBox(
              height: keyHeight,
              width: double.infinity,
              child: FilledButton(
                onPressed: onEnter,
                child: Text(enterLabel, style: const TextStyle(fontSize: 20)),
              ),
            ),
          ),
      ],
    );
  }
}
