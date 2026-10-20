import 'built_in_player_service.dart';
import 'car_music_queue_controller.dart';
import 'car_music_sync_service.dart';

class CustomActionItem {
  final String action;
  final String name;
  final int? icon;
  final Map<String, String> extras;

  const CustomActionItem({
    required this.action,
    required this.name,
    this.icon,
    this.extras = const {},
  });

  factory CustomActionItem.fromMap(Map<dynamic, dynamic> map) {
    final rawExtras = map['extras'];
    final extrasMap = <String, String>{};
    if (rawExtras is Map) {
      rawExtras.forEach((k, v) {
        extrasMap[k.toString()] = v?.toString() ?? '';
      });
    }

    return CustomActionItem(
      action: map['action']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      icon: map['icon'] is int ? map['icon'] as int : null,
      extras: extrasMap,
    );
  }
}

class PlaybackInfo {
  final bool hasPermission;
  final bool sessionFound;
  final String title;
  final String artist;
  final String album;
  final int stateCode;
  final String stateName;
  final int positionMs;
  final int actionsMask;
  final int repeatMode;
  final int shuffleMode;
  final List<CustomActionItem> customActions;
  final String message;

  const PlaybackInfo({
    required this.hasPermission,
    required this.sessionFound,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.stateCode = 0,
    this.stateName = '未知',
    this.positionMs = 0,
    this.actionsMask = 0,
    this.repeatMode = -1,
    this.shuffleMode = -1,
    this.customActions = const [],
    this.message = '',
  });

  bool get isPlaying => stateCode == 3; // PlaybackState.STATE_PLAYING == 3

  factory PlaybackInfo.fromMap(Map<dynamic, dynamic> map) {
    final rawActions = map['customActions'];
    final actionItems = <CustomActionItem>[];
    if (rawActions is List) {
      for (final a in rawActions) {
        if (a is Map) {
          actionItems.add(CustomActionItem.fromMap(a));
        }
      }
    }

    return PlaybackInfo(
      hasPermission: map['hasPermission'] == true,
      sessionFound: map['sessionFound'] == true,
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      album: map['album']?.toString() ?? '',
      stateCode: (map['stateCode'] as num?)?.toInt() ?? 0,
      stateName: map['stateName']?.toString() ?? '未知',
      positionMs: (map['positionMs'] as num?)?.toInt() ?? 0,
      actionsMask: (map['actionsMask'] as num?)?.toInt() ?? 0,
      repeatMode: (map['repeatMode'] as num?)?.toInt() ?? -1,
      shuffleMode: (map['shuffleMode'] as num?)?.toInt() ?? -1,
      customActions: actionItems,
      message: map['message']?.toString() ?? '',
    );
  }
}

/// Home-page adapter for the same backend/controller/engine pipeline.
class MusicService {
  Future<bool> isNotificationAccessGranted() async => true;
  Future<bool> openNotificationAccessSettings() async => false;

  Future<PlaybackInfo> getPlaybackInfo() async {
    final service = BuiltInPlayerService();
    final ctrl = CarMusicQueueController();
    final current = service.currentTrack;
    return PlaybackInfo(hasPermission: true, sessionFound: current.id.isNotEmpty,
      title: current.title, artist: current.artist, album: current.tag,
      stateCode: service.stopped ? 1 : service.player.playing ? 3 : 2,
      stateName: service.stopped ? '停止' : service.player.playing ? '播放中' : '已暂停',
      positionMs: service.player.position.inMilliseconds,
      repeatMode: ctrl.appliedMode.value == 'single_loop' ? 1 : 2,
      shuffleMode: ctrl.appliedMode.value == 'shuffle' ? 1 : 0,
      message: ctrl.errorDetail ?? '未选择来源时，点播放将使用完整喜欢歌单');
  }

  Future<Map<String, dynamic>> _request(String action, [Map<String, dynamic> params = const {}]) async {
    final sync = CarMusicSyncService();
    await sync.requestLocalCommand(action, params);
    // Submission is distinct from car execution; never return fabricated success.
    return {'message': sync.lastCommandNotifier.value};
  }

  Future<Map<String, dynamic>> togglePlayPause() =>
    _request(BuiltInPlayerService().player.playing ? 'pause' : 'resume');
  Future<Map<String, dynamic>> skipToNext() => _request('next');
  Future<Map<String, dynamic>> skipToPrevious() => _request('prev');
}
