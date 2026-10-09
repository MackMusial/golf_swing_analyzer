import 'package:flutter/material.dart';

import 'screens/home_screen.dart';

void main() => runApp(const SwingApp());

class SwingApp extends StatelessWidget {
  const SwingApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF1B7F3B); // fairway green
    return MaterialApp(
      title: 'Swing Analyzer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
