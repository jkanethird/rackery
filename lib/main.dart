import 'package:flutter/material.dart';
import 'package:system_theme/system_theme.dart';
import 'package:ebird_generator/ui/main_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemTheme.accentColor.load();

  LicenseRegistry.addLicense(() async* {
    final emojiLicense = await rootBundle.loadString('assets/LICENSE_EMOJI.md');
    yield LicenseEntryWithLineBreaks(['Emoji Kitchen Icon'], emojiLicense);

    final bioClipLicense = await rootBundle.loadString(
      'assets/LICENSE_BIOCLIP.md',
    );
    yield LicenseEntryWithLineBreaks(['BioCLIP Vision Model'], bioClipLicense);
  });

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return SystemThemeBuilder(
      builder: (context, accent) {
        return MaterialApp(
          title: 'Rackery',
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent.accent,
              brightness: Brightness.dark,
              surface: HSLColor.fromColor(
                accent.darkest,
              ).withLightness(0.025).toColor(),
            ),
            useMaterial3: true,
          ),
          themeMode: ThemeMode.dark,
          home: const MainScreen(),
        );
      },
    );
  }
}
