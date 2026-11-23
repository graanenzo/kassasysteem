/// Full on-screen keyboard (letters and digits) for the search field. On an
/// iPad with a scanner attached the system keyboard stays hidden.
///
/// Hoofdletters: ⇧ één keer tikken = volgende letter een hoofdletter,
/// twee keer tikken (of lang indrukken) = hoofdletters vast (caps lock).
/// Met [autoCapitalize] begint elk woord vanzelf met een hoofdletter
/// (voor namen en adressen op een factuur).
library;

import 'package:flutter/material.dart';

enum _Shift { off, once, locked }

class OnScreenKeyboard extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onChanged;
  final VoidCallback onEnter;
  final VoidCallback onClose;

  /// Elk nieuw woord begint met een hoofdletter (uit te zetten met ⇧).
  final bool autoCapitalize;

  const OnScreenKeyboard({
    super.key,
    required this.controller,
    required this.onChanged,
    required this.onEnter,
    required this.onClose,
    this.autoCapitalize = false,
  });

  @override
  State<OnScreenKeyboard> createState() => _OnScreenKeyboardState();
}

class _OnScreenKeyboardState extends State<OnScreenKeyboard> {
  _Shift _shift = _Shift.off;
  DateTime _lastShiftTap = DateTime(0);

  @override
  void initState() {
    super.initState();
    _autoShift();
  }

  @override
  void didUpdateWidget(covariant OnScreenKeyboard old) {
    super.didUpdateWidget(old);
    // ander veld gekozen (bijv. naam -> adres)
    if (old.controller != widget.controller && _shift != _Shift.locked) {
      _shift = _Shift.off;
      _autoShift();
    }
  }

  /// Bij [OnScreenKeyboard.autoCapitalize]: hoofdletter aan het begin van een woord.
  void _autoShift() {
    if (!widget.autoCapitalize || _shift == _Shift.locked) return;
    final t = widget.controller.text;
    if (t.isEmpty || t.endsWith(' ') || t.endsWith('\n')) _shift = _Shift.once;
  }

  void _set(String text) {
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onChanged();
  }

  void _type(String k) {
    final upper = _shift != _Shift.off;
    _set(widget.controller.text + (upper ? k.toUpperCase() : k));
    setState(() {
      if (_shift == _Shift.once) _shift = _Shift.off;
      _autoShift();
    });
  }

  void _tapShift() {
    final now = DateTime.now();
    final doubleTap = now.difference(_lastShiftTap) < const Duration(milliseconds: 400);
    _lastShiftTap = now;
    setState(() {
      if (doubleTap) {
        _shift = _Shift.locked;
      } else {
        _shift = _shift == _Shift.off ? _Shift.once : _Shift.off;
      }
    });
  }

  Widget _key(String label, VoidCallback onTap,
      {int flex = 2, bool action = false, VoidCallback? onLongPress, bool active = false}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          height: 52,
          child: active
              ? FilledButton(
                  onPressed: onTap,
                  onLongPress: onLongPress,
                  style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                  child: Text(label, style: const TextStyle(fontSize: 20)),
                )
              : action
                  ? OutlinedButton(
                      onPressed: onTap,
                      onLongPress: onLongPress,
                      style: OutlinedButton.styleFrom(padding: EdgeInsets.zero),
                      child: Text(label, style: const TextStyle(fontSize: 18)),
                    )
                  : FilledButton.tonal(
                      onPressed: onTap,
                      onLongPress: onLongPress,
                      style: FilledButton.styleFrom(padding: EdgeInsets.zero),
                      child: Text(label, style: const TextStyle(fontSize: 22)),
                    ),
        ),
      ),
    );
  }

  Widget _row(String keys,
      {int indent = 0, List<Widget> leading = const [], List<Widget> trailing = const []}) {
    final upper = _shift != _Shift.off;
    return Row(children: [
      if (indent > 0) Spacer(flex: indent),
      ...leading,
      for (final k in keys.split(''))
        _key(upper ? k.toUpperCase() : k, () => _type(k)),
      ...trailing,
      if (indent > 0) Spacer(flex: indent),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.controller.text;
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
            _row('zxcvbnm', leading: [
              _key(_shift == _Shift.locked ? '⇪' : '⇧', _tapShift,
                  flex: 3,
                  action: true,
                  active: _shift != _Shift.off,
                  onLongPress: () => setState(() => _shift = _Shift.locked)),
            ], trailing: [
              _key('⌫', () {
                if (t.isNotEmpty) _set(t.substring(0, t.length - 1));
                setState(() {
                  if (_shift == _Shift.once) _shift = _Shift.off;
                  _autoShift();
                });
              }, flex: 3, action: true),
            ]),
            Row(children: [
              _key('Sluiten', widget.onClose, flex: 4, action: true),
              _key('Wissen', () {
                _set('');
                setState(_autoShift);
              }, flex: 3, action: true),
              _key('-', () => _type('-'), flex: 2),
              _key('spatie', () => _type(' '), flex: 8),
              _key('.', () => _type('.'), flex: 2),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: SizedBox(
                    height: 52,
                    child: FilledButton(
                      onPressed: widget.onEnter,
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
