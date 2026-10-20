import 'package:flutter_test/flutter_test.dart';
import 'package:my_yaris/services/built_in_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BuiltInPlayerService Model & Offline Tracks Tests', () {
    test('Cold product player has no sample fallback or selected source', () {
      final service = BuiltInPlayerService();
      expect(service.tracks, isEmpty);
      expect(service.currentTrack.id, isEmpty);
      expect(service.currentTrack.isLocal, false);
    });

    test('Initial volume is limited to safe low level (<= 30%)', () {
      final service = BuiltInPlayerService();
      expect(service.currentVolume <= 0.30, true);
    });
  });
}
