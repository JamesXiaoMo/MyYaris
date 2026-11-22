import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

class AppUpdateInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String? apkUrl;
  final int apkSizeBytes;
  final bool hasUpdate;

  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.apkUrl,
    required this.apkSizeBytes,
    required this.hasUpdate,
  });
}

class AppUpdateService {
  static const String currentVersion = '1.2.1';
  static const String latestReleaseApi =
      'https://api.github.com/repos/JamesXiaoMo/MyYaris/releases/latest';
  static const MethodChannel _channel =
      MethodChannel('com.myyaris.my_yaris/updater');

  static String? _cachedVersion;

  /// Reads the real installed Android `versionName` dynamically from PackageManager.
  static Future<String> getCurrentVersion() async {
    if (_cachedVersion != null && _cachedVersion!.isNotEmpty) {
      return _cachedVersion!;
    }
    try {
      final v = await _channel.invokeMethod<String>('getAppVersion');
      if (v != null && v.trim().isNotEmpty) {
        _cachedVersion = v.trim();
        return _cachedVersion!;
      }
    } catch (_) {}
    return currentVersion;
  }

  static bool isNewerVersion(String remote, String local) {
    List<int> parse(String v) {
      final clean = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
      return clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    }

    final r = parse(remote);
    final l = parse(local);
    final len = r.length > l.length ? r.length : l.length;
    for (var i = 0; i < len; i++) {
      final rv = i < r.length ? r[i] : 0;
      final lv = i < l.length ? l[i] : 0;
      if (rv != lv) return rv > lv;
    }
    return false;
  }

  Future<AppUpdateInfo> checkForUpdate() async {
    final localVersion = await getCurrentVersion();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(latestReleaseApi));
      req.headers.set(HttpHeaders.userAgentHeader, 'MyYaris-CarApp/$localVersion');
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      final res = await req.close().timeout(const Duration(seconds: 12));
      final body = await utf8.decodeStream(res);
      if (res.statusCode == 404) {
        return AppUpdateInfo(
          currentVersion: localVersion,
          latestVersion: localVersion,
          releaseNotes: 'GitHub 仓库暂无已发布的 Release 版本',
          apkUrl: null,
          apkSizeBytes: 0,
          hasUpdate: false,
        );
      }
      if (res.statusCode != 200) {
        throw HttpException('GitHub API 返回状态 ${res.statusCode}');
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '').toString().trim();
      final notes = (data['body'] ?? '').toString().trim();
      String? apkUrl;
      int apkSize = 0;
      final assets = data['assets'];
      if (assets is List) {
        for (final a in assets) {
          if (a is Map) {
            final name = (a['name'] ?? '').toString().toLowerCase();
            final url = (a['browser_download_url'] ?? '').toString();
            if (name.endsWith('.apk') && url.startsWith('https://')) {
              apkUrl = url;
              apkSize = (a['size'] as num?)?.toInt() ?? 0;
              break;
            }
          }
        }
      }
      final cleanLatest = tag.replaceFirst(RegExp(r'^[vV]'), '');
      final hasUpdate = cleanLatest.isNotEmpty &&
          isNewerVersion(cleanLatest, localVersion) &&
          apkUrl != null;
      return AppUpdateInfo(
        currentVersion: localVersion,
        latestVersion: cleanLatest.isEmpty ? localVersion : cleanLatest,
        releaseNotes: notes,
        apkUrl: apkUrl,
        apkSizeBytes: apkSize,
        hasUpdate: hasUpdate,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads APK from GitHub Release and launches Android system installer.
  /// Returns 'STARTED' or 'PERMISSION_REQUIRED'.
  Future<String> downloadAndInstall({
    required String apkUrl,
    void Function(double progress)? onProgress,
  }) async {
    final dirPath = await _channel.invokeMethod<String>('getUpdateCacheDir');
    if (dirPath == null || dirPath.isEmpty) {
      throw StateError('无法访问车机缓存目录');
    }
    final target = File('$dirPath/myyaris-update.apk');
    final tmp = File('$dirPath/myyaris-update.apk.part');
    if (await tmp.exists()) await tmp.delete();

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(Uri.parse(apkUrl));
      req.headers.set(HttpHeaders.userAgentHeader, 'MyYaris-CarApp/$currentVersion');
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) {
        throw HttpException('下载更新失败（HTTP ${res.statusCode}）');
      }
      final total = res.contentLength;
      int received = 0;
      final sink = tmp.openWrite();
      try {
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (total > 0 && onProgress != null) {
            onProgress((received / total).clamp(0.0, 1.0));
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
    } finally {
      client.close(force: true);
    }

    final status = await _channel.invokeMethod<String>('installApk', {'path': target.path});
    return status ?? 'STARTED';
  }
}
