import 'package:flutter/material.dart';
import 'services/storage_service.dart';
import 'services/task_poller_service.dart';
import 'ui/car_home_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = await SharedPreferencesStorageService.create();
  final poller = TaskPollerService(storage: storage);
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
