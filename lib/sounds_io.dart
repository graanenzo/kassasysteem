import 'package:audioplayers/audioplayers.dart';

AudioPlayer? _ok;
AudioPlayer? _error;

/// Loads the sounds once, so playing them later starts immediately.
Future<void> initSounds() async {
  try {
    _ok = AudioPlayer();
    _error = AudioPlayer();
    await _ok!.setReleaseMode(ReleaseMode.stop);
    await _error!.setReleaseMode(ReleaseMode.stop);
    await _ok!.setSource(AssetSource('sounds/ok.wav'));
    await _error!.setSource(AssetSource('sounds/error.wav'));
  } catch (_) {}
}

void unlockSounds() {}

bool soundsReady() => true;

Future<void> _replay(AudioPlayer? p) async {
  if (p == null) return;
  try {
    await p.seek(Duration.zero);
    await p.resume();
  } catch (_) {}
}

void playOk() => _replay(_ok);
void playError() => _replay(_error);
