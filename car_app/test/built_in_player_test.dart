import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/built_in_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BuiltInPlayerService Model & Offline Tracks Tests', () {
    test('Service defines exactly 3 offline WAV tracks', () {
      final service = BuiltInPlayerService();
      expect(service.tracks.length, 3);

      // Verify 3 distinct local tracks
      final localTracks = service.tracks.where((t) => t.isLocal).toList();
      expect(localTracks.length, 3);
      expect(localTracks[0].assetPath, 'assets/audio/track1_bell_melody.wav');
      expect(localTracks[1].assetPath, 'assets/audio/track2_bass_groove.wav');
      expect(localTracks[2].assetPath, 'assets/audio/track3_ambient_pad.wav');
    });

    test('Initial volume is limited to safe low level (<= 30%)', () {
      final service = BuiltInPlayerService();
      expect(service.currentVolume <= 0.30, true);
    });
  });
}
