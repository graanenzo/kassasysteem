/// Short beeps for scan feedback: a high blip when a product is added and
/// a low double tone when a code is not recognised.
library;

import 'package:audioplayers/audioplayers.dart';

final _ok = AudioPlayer()..setPlayerMode(PlayerMode.lowLatency);
final _error = AudioPlayer()..setPlayerMode(PlayerMode.lowLatency);

Future<void> playOk() async {
  try {
    await _ok.stop();
    await _ok.play(AssetSource('sounds/ok.wav'));
  } catch (_) {}
}

Future<void> playError() async {
  try {
    await _error.stop();
    await _error.play(AssetSource('sounds/error.wav'), volume: 1.0);
  } catch (_) {}
}
