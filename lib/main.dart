import 'package:flutter/material.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/ui/main_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BirdClassifier().unloadModel();

  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/LICENSE_EMOJI.md');
    yield LicenseEntryWithLineBreaks(['Emoji Kitchen Icon'], license);
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'eBird Checklist Generator',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blueGrey,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.dark,
      home: const MainScreen(),
    );
  }
}
