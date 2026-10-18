import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'services/built_in_player_service.dart';
import 'services/car_audio_handler.dart';
import 'services/car_music_sync_service.dart';
import 'services/storage_service.dart';
import 'services/system_ui_service.dart';
import 'services/task_poller_service.dart';
import 'ui/car_home_page.dart';

AudioHandler? globalAudioHandler;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await SharedPreferencesStorageService.create();
  final poller = TaskPollerService(storage: storage);

  // Apply fullscreen setting as early as possible to prevent status bar flashing
  await SystemUiService.setFullscreen(storage.isFullscreenEnabled);

  // 1. Initialize AudioService for Android MediaSession and Notification controls
  try {
    globalAudioHandler = await AudioService.init(
      builder: () => CarAudioHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.myyaris.my_yaris.channel.audio',
        androidNotificationChannelName: 'MyYaris 音乐播放',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationIcon: 'mipmap/ic_launcher',
      ),
    );
  } catch (e) {
    debugPrint('[Main] AudioService init note: $e');
  }

  // 2. Pre-initialize BuiltInPlayerService
  try {
    await BuiltInPlayerService().init();
  } catch (e) {
    debugPrint('[Main] BuiltInPlayerService init note: $e');
  }

  // 3. Connect CarMusicSyncService into application-level lifecycle
  if (storage.backendUrl.isNotEmpty) {
    CarMusicSyncService().start(
      baseUrl: storage.backendUrl,
      deviceId: storage.deviceId,
      token: storage.carToken,
      fallbackDns: storage.fallbackDns,
    );
  }

  runApp(MyYarisApp(storage: storage, poller: poller));
}

class MyYarisApp extends StatelessWidget {
  final IStorageService storage;
  final TaskPollerService poller;

  const MyYarisApp({
    super.key,
    required this.storage,
    required this.poller,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyYaris 车机助手',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121418),
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueAccent,
          brightness: Brightness.dark,
        ),
      ),
      home: CarHomePage(storage: storage, poller: poller),
    );
  }
}
