import 'package:flutter/material.dart';

import 'ui/about_dialog.dart';
import 'ui/connect_page.dart';

void main() {
  runApp(const DshFlutterApp());
}

class DshFlutterApp extends StatelessWidget {
  const DshFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppName,
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        brightness: Brightness.dark,
      ),
      home: const ConnectPage(),
    );
  }
}
