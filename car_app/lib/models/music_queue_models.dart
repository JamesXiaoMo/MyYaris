import 'package:flutter/foundation.dart';

/// Supported playback modes defined in V2.2.0 contract
enum PlaybackMode {
  listLoop('list_loop'),
  shuffle('shuffle'),
  intelligence('intelligence'),
  singleLoop('single_loop');

  final String value;
  const PlaybackMode(this.value);

  static PlaybackMode fromString(String? val) {
    if (val == null) return PlaybackMode.listLoop;
    final lower = val.toLowerCase().trim();
    for (final mode in PlaybackMode.values) {
      if (mode.value == lower) return mode;
    }
    // Backward compatibility mappings
    if (lower == 'all' || lower == 'repeat' || lower == 'loop') {
      return PlaybackMode.listLoop;
    }
    if (lower == 'one' || lower == 'single') {
      return PlaybackMode.singleLoop;
    }
    if (lower == 'random') {
      return PlaybackMode.shuffle;
    }
    return PlaybackMode.listLoop;
  }
}

/// Supported queue source types defined in V2.2.0 contract
class QueueSource {
  static const String neteaseFavorite = 'netease_favorite';
  static const String neteaseIntelligence = 'netease_intelligence';
  static const String singleTrack = 'single_track';
}

/// Single queue track item conforming to Section 3.1 of V2.2.0 contract
@immutable
class NeteaseQueueTrackItem {
  final String trackId;
  final int songId;
  final String title;
  final String artist;
  final String? album;
  final int durationMs;
  final String? coverUrl;
  final String streamUrl;
  final int fee;
  final bool? playable;
  final int queueIndex;

  const NeteaseQueueTrackItem({
    required this.trackId,
    required this.songId,
    required this.title,
    required this.artist,
    this.album,
    this.durationMs = 0,
    this.coverUrl,
    required this.streamUrl,
    this.fee = 0,
    this.playable,
    required this.queueIndex,
  });

  factory NeteaseQueueTrackItem.fromJson(Map<String, dynamic> json, {int? fallbackIndex}) {
    final rawSongId = json['song_id'] ?? json['id'];
    final songId = rawSongId is int ? rawSongId : (int.tryParse(rawSongId?.toString() ?? '') ?? 0);
    final rawTrackId = json['track_id']?.toString() ?? 'netease_$songId';

    return NeteaseQueueTrackItem(
      trackId: rawTrackId,
      songId: songId,
      title: json['title']?.toString() ?? '未知曲目',
      artist: json['artist']?.toString() ?? '未知歌手',
      album: json['album']?.toString(),
      durationMs: (json['duration_ms'] as num?)?.toInt() ?? 0,
      coverUrl: json['cover_url']?.toString(),
      streamUrl: json['stream_url']?.toString() ?? '/api/v1/music/netease/stream/$songId',
      fee: (json['fee'] as num?)?.toInt() ?? 0,
      playable: json['playable'] as bool?,
      queueIndex: (json['queue_index'] as num?)?.toInt() ?? fallbackIndex ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'track_id': trackId,
      'song_id': songId,
      'title': title,
      'artist': artist,
      if (album != null) 'album': album,
      'duration_ms': durationMs,
      if (coverUrl != null) 'cover_url': coverUrl,
      'stream_url': streamUrl,
      'fee': fee,
      'playable': playable,
      'queue_index': queueIndex,
    };
  }

  NeteaseQueueTrackItem copyWith({
    String? trackId,
    int? songId,
    String? title,
    String? artist,
    String? album,
    int? durationMs,
    String? coverUrl,
    String? streamUrl,
    int? fee,
    bool? playable,
    int? queueIndex,
  }) {
    return NeteaseQueueTrackItem(
      trackId: trackId ?? this.trackId,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationMs: durationMs ?? this.durationMs,
      coverUrl: coverUrl ?? this.coverUrl,
      streamUrl: streamUrl ?? this.streamUrl,
      fee: fee ?? this.fee,
      playable: playable ?? this.playable,
      queueIndex: queueIndex ?? this.queueIndex,
    );
  }
}

/// Response payload from GET /api/v1/music/queue conforming to Section 3.2
class MusicQueueSnapshot {
  final int code;
  final String queueId;
  final int queueVersion;
  final String source;
  final String? name;
  final int total;
  final bool isComplete;
  final String queueState;
  final int offset;
  final int limit;
  final bool hasMore;
  final List<NeteaseQueueTrackItem> tracks;

  const MusicQueueSnapshot({
    required this.code,
    required this.queueId,
    required this.queueVersion,
    required this.source,
    this.name,
    required this.total,
    required this.isComplete,
    this.queueState = 'ready',
    required this.offset,
    required this.limit,
    required this.hasMore,
    required this.tracks,
  });

  factory MusicQueueSnapshot.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'] as List? ?? [];
    final offset = (json['offset'] as num?)?.toInt() ?? 0;
    final tracks = <NeteaseQueueTrackItem>[];
    for (int i = 0; i < rawTracks.length; i++) {
      if (rawTracks[i] is Map<String, dynamic>) {
        tracks.add(NeteaseQueueTrackItem.fromJson(
          rawTracks[i] as Map<String, dynamic>,
          fallbackIndex: offset + i,
        ));
      }
    }

    return MusicQueueSnapshot(
      code: (json['code'] as num?)?.toInt() ?? 200,
      queueId: json['queue_id']?.toString() ?? '',
      queueVersion: (json['queue_version'] as num?)?.toInt() ?? 1,
      source: json['source']?.toString() ?? QueueSource.neteaseFavorite,
      name: json['name']?.toString(),
      total: (json['total'] as num?)?.toInt() ?? tracks.length,
      isComplete: json['is_complete'] as bool? ?? false,
      queueState: json['queue_state']?.toString() ?? 'ready',
      offset: offset,
      limit: (json['limit'] as num?)?.toInt() ?? (tracks.isNotEmpty ? tracks.length : 50),
      hasMore: json['has_more'] as bool? ?? false,
      tracks: tracks,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'queue_id': queueId,
      'queue_version': queueVersion,
      'source': source,
      if (name != null) 'name': name,
      'total': total,
      'is_complete': isComplete,
      'queue_state': queueState,
      'offset': offset,
      'limit': limit,
      'has_more': hasMore,
      'tracks': tracks.map((t) => t.toJson()).toList(),
    };
  }
}
