import 'package:flutter/material.dart';

void main() {
  runApp(const MyYarisApp());
}

class MyYarisApp extends StatelessWidget {
  const MyYarisApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MyYaris',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF121418),
      ),
      home: const Scaffold(
        backgroundColor: Color(0xFF121418),
        body: SizedBox.shrink(),
      ),
    );
  }
}
