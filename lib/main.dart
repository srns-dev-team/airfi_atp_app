import 'package:flutter/material.dart';

import 'screens/device_list_screen.dart';

void main() => runApp(const AirfiAtpApp());

class AirfiAtpApp extends StatelessWidget {
  const AirfiAtpApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00B4D8),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'AirFi ATP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0E1116),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: const DeviceListScreen(),
    );
  }
}
