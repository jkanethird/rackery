// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'package:flutter/material.dart';
import 'package:system_theme/system_theme.dart';
import 'package:rackery/ui/main_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:rackery/src/rust/frb_generated.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
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
          ),
          themeMode: ThemeMode.dark,
          home: const MainScreen(),
        );
      },
    );
  }
}
