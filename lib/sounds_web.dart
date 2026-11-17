import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

// Tones are generated with the Web Audio API: nothing to download or
// decode, so they start the instant they are triggered.
web.AudioContext? _ctx;

Future<void> initSounds() async {
  // Safari 17+: play like a media app, so the error tone is also heard when
  // the iPad is set to silent.
  try {
    final nav = globalContext['navigator'] as JSObject?;
    final session = nav?['audioSession'] as JSObject?;
    session?['type'] = 'playback'.toJS;
  } catch (_) {}
}

/// False while Safari still blocks sound (until the screen is tapped).
bool soundsReady() {
  final ctx = _ctx;
  return ctx != null && ctx.state == 'running';
}

/// Safari only allows sound after a touch; call this on the first tap.
void unlockSounds() {
  try {
    final ctx = _ctx ??= web.AudioContext();
    if (ctx.state != 'running') ctx.resume();
  } catch (_) {}
}

void _tones(List<(double, double)> parts) {
  try {
    final ctx = _ctx ??= web.AudioContext();
    if (ctx.state != 'running') ctx.resume();
    var t = ctx.currentTime;
    for (final (freq, dur) in parts) {
      if (freq > 0) {
        final osc = ctx.createOscillator();
        final gain = ctx.createGain();
        osc.type = 'square';
        osc.frequency.value = freq;
        gain.gain.setValueAtTime(0.2, t);
        gain.gain.setValueAtTime(0, t + dur);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(t);
        osc.stop(t + dur);
      }
      t += dur;
    }
  } catch (_) {}
}

void playOk() => _tones([(1400, 0.07)]);
void playError() => _tones([(330, 0.18), (0, 0.08), (220, 0.3)]);
