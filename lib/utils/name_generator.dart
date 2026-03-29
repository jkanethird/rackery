import 'dart:math';

final _random = Random();
const _consonants = ['b', 'c', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'm', 'n', 'p', 'r', 's', 't', 'v', 'w', 'y', 'z'];
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
