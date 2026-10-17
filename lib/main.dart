import 'package:flutter/material.dart';

import 'screens/profile_list_screen.dart';

void main() {
  runApp(const FormFillerApp());
}

class FormFillerApp extends StatelessWidget {
  const FormFillerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Form Filler',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const ProfileListScreen(),
    );
  }
}
