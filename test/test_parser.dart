// ignore_for_file: avoid_print, avoid_relative_lib_imports
import '../lib/services/bird_names.dart';

void main() {
  const responseText = r'''
The bird inside the red rectangle appears to be a small shorebird with a long, pointed bill and a black and white or brownish-gray back. The wings are long and pointed, and the tail is long and forked. The bird's legs are orange or red.

Based on these characteristics, my top 5 species guesses are:

1. Sanderling (Sanderling)
2. Ruddy Turnstone (Rarhulus
3. Red Knot (Calidris
4. Black-bellied Plover (S. J. . . . . . . . . . . . . . . . . . . . . . . . . . . . . . . .
''';

  List<String> extractedLines = [];
  
  // Try to grab numbered list items
  final listRegex = RegExp(r'^\s*\d+\.\s*(.+)$', multiLine: true);
  for (final match in listRegex.allMatches(responseText)) {
    extractedLines.add(match.group(1)!.trim());
  }
  
  print("Extracted lines: $extractedLines");
  
  List<String> finalGuesses = [];
  Set<String> seenSci = {};
  
  for (String line in extractedLines) {
    if (line.toLowerCase().contains("unknown")) continue;
    
    // Find the longest common name from our global list that exists in this line
    String? bestCommon;
    String? bestSci;
    
    for (final entry in scientificToCommon.entries) {
      if (line.toLowerCase().contains(entry.value.toLowerCase())) {
        if (bestCommon == null || entry.value.length > bestCommon.length) {
          bestCommon = entry.value;
          bestSci = entry.key;
        }
      }
    }
    
    if (bestCommon != null && bestSci != null) {
       if (!seenSci.contains(bestSci)) {
          seenSci.add(bestSci);
          finalGuesses.add("$bestCommon ($bestSci)");
       }
    }
  }
  
  print("Final Guesses: $finalGuesses");
}
