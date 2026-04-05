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

// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'package:rackery/services/exif_service.dart';

void main() async {
  final exifs = [
    '/home/jkane/test photos/IMG_3834.HEIC',
    '/home/jkane/test photos/IMG_3835.HEIC',
    '/home/jkane/test photos/IMG_3836.HEIC',
  ];
  for (final path in exifs) {
    final exif = await ExifService.extractExif(path);
    print('$path: $exif');
  }
}
