import 'package:flutter/services.dart';

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

class MusicService {
  static const MethodChannel _channel = MethodChannel('com.myyaris.my_yaris/music');

  Future<bool> isNotificationAccessGranted() async {
    try {
      final res = await _channel.invokeMethod<bool>('isNotificationAccessGranted');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openNotificationAccessSettings() async {
    try {
      final res = await _channel.invokeMethod<bool>('openNotificationAccessSettings');
      return res ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<PlaybackInfo> getPlaybackInfo() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPlaybackInfo');
      if (res != null) {
        return PlaybackInfo.fromMap(res);
      }
      return const PlaybackInfo(hasPermission: false, sessionFound: false, message: '返回为空');
    } catch (e) {
      return PlaybackInfo(
        hasPermission: false,
        sessionFound: false,
        message: '调用异常: $e',
      );
    }
  }

  Future<Map<String, dynamic>> togglePlayPause() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('togglePlayPause');
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '操作失败: $e'};
    }
  }

  Future<Map<String, dynamic>> skipToNext() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('skipToNext');
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '操作失败: $e'};
    }
  }

  Future<Map<String, dynamic>> skipToPrevious() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('skipToPrevious');
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '操作失败: $e'};
    }
  }

  Future<Map<String, dynamic>> sendCustomAction(String action, [Map<String, String>? extras]) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('sendCustomAction', {
        'action': action,
        'extras': ?extras,
      });
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '发送失败: $e'};
    }
  }

  Future<Map<String, dynamic>> openSongPage(String input) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('openSongPage', {
        'input': input,
      });
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '打开失败: $e'};
    }
  }

  Future<Map<String, dynamic>> openPlaylistPage(String input) async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('openPlaylistPage', {
        'input': input,
      });
      return Map<String, dynamic>.from(res ?? {});
    } catch (e) {
      return {'success': false, 'message': '打开失败: $e'};
    }
  }
}
