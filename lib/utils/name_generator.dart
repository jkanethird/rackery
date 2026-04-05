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

import 'dart:math';

final _random = Random();
const _consonants = [
  'b',
  'c',
  'd',
  'f',
  'g',
  'h',
  'j',
  'k',
  'l',
  'm',
  'n',
  'p',
  'r',
  's',
  't',
  'v',
  'w',
  'y',
  'z',
];
const _vowels = ['a', 'e', 'i', 'o', 'u'];

String generatePronounceableName() {
  final length = _random.nextInt(2) + 2; // 2 to 3 syllables (4-6 chars)
  final buffer = StringBuffer();
  for (int i = 0; i < length * 2; i++) {
    if (i % 2 == 0) {
      buffer.write(_consonants[_random.nextInt(_consonants.length)]);
    } else {
      buffer.write(_vowels[_random.nextInt(_vowels.length)]);
    }
  }

  final str = buffer.toString();
  return str[0].toUpperCase() + str.substring(1);
}
