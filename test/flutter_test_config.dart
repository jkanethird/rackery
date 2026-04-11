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

import 'dart:async';
import 'dart:io';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.isWindows) {
    // tflite_flutter resolves the native DLL relative to
    // Platform.resolvedExecutable, which during `flutter test` points to
    // flutter_tester.exe inside the engine cache — not the project build
    // output. Copy the DLL there so the dynamic library load succeeds.
    final testerDir = Directory(Platform.resolvedExecutable).parent.path;
    final target = File('$testerDir/blobs/libtensorflowlite_c-win.dll');

    if (!target.existsSync()) {
      final source = File('blobs/libtensorflowlite_c-win.dll');
      if (source.existsSync()) {
        await Directory('$testerDir/blobs').create(recursive: true);
        await source.copy(target.path);
      }
    }
  }

  await testMain();
}
