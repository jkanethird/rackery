import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:ebird_generator/services/bird_names.dart';

/// Parses the raw JSON body from the Ollama API and resolves species names
/// against the eBird taxonomy dictionary.
class SpeciesNameResolver {
  /// Parses [body] (the Ollama `generate` response JSON) and returns a list
  /// of matched eBird common names, in the order the model suggested them.
  ///
  /// Returns an **empty list** when the model explicitly reported no bird
  /// (i.e. it responded with "0. none"). Callers should treat an empty result
  /// as a signal to skip observation creation for that crop.
  ///
  /// Falls back to `["Unknown Bird"]` when no recognisable species are found
  /// but the model did not explicitly say "none".
  static List<String> parseOllamaResponse(String body) {
    try {
      final data = jsonDecode(body);
      final responseText = data['response'].toString().trim();

      List<String> rawSpeciesList = [];

      // 1. Numbered list items  "1. Mute Swan"
      final listRegex = RegExp(r'^\s*\d+\.\s*(.+)$', multiLine: true);
      for (final match in listRegex.allMatches(responseText)) {
        rawSpeciesList.add(match.group(1)!.trim());
      }

      // 2. "Common Name (Scientific Name)" patterns
      if (rawSpeciesList.isEmpty) {
        final speciesNameRegex = RegExp(
          r"([A-Za-z \-'\.,]+?\s*\([A-Z][a-z]+ [a-z]+\))",
        );
        for (final m in speciesNameRegex.allMatches(responseText)) {
          rawSpeciesList.add(m.group(1)!.trim());
        }
      }

      // 3. Bulleted items  "- Mute Swan"
      if (rawSpeciesList.isEmpty) {
        final bulletRegex = RegExp(r'[-*]\s*"?([^"\n]+)"?');
        for (final m in bulletRegex.allMatches(responseText)) {
          rawSpeciesList.add(m.group(1)!.trim());
        }
      }

      if (rawSpeciesList.isEmpty) return ["Unknown Bird"];

      // If the model responded with the no-bird sentinel ("0. none"), return
      // an empty list so PhotoProcessor knows to skip this crop entirely.
      if (rawSpeciesList.length == 1 &&
          rawSpeciesList.first.trim().toLowerCase() == 'none') {
        return [];
      }

      return _resolveNames(rawSpeciesList);
    } catch (e) {
      debugPrint('Failed to parse LLM JSON response: $e');
      return ["Unknown Bird"];
    }
  }

  /// Matches each raw LLM guess to the best eBird common name using three
  /// passes: exact substring, generic "sp." lookup, shortest word-boundary match.
  static List<String> _resolveNames(List<String> rawList) {
    final List<String> processedSpecies = [];
    final Set<String> seenScientifics = {};

    for (final raw in rawList) {
      if (raw.isEmpty) continue;
      final lowerRaw = raw.toLowerCase();
      if (lowerRaw.contains('unknown') && !lowerRaw.contains('(')) continue;

      String? bestCommon;
      String? bestSci;

      // Pass 1: eBird name is contained within the LLM output (longest match wins)
      for (final entry in scientificToCommon.entries) {
        if (entry.value.trim().isEmpty) continue;
        if (lowerRaw.contains(entry.value.toLowerCase())) {
          if (bestCommon == null || entry.value.length > bestCommon.length) {
            bestCommon = entry.value;
            bestSci = entry.key;
          }
        }
      }

      // Pass 2: LLM gave a generic name → look for "X sp." in eBird
      if (bestCommon == null) {
        for (final entry in scientificToCommon.entries) {
          final ebirdLower = entry.value.toLowerCase();
          if (ebirdLower == '$lowerRaw sp.' || ebirdLower == '$lowerRaw sp') {
            bestCommon = entry.value;
            bestSci = entry.key;
            break;
          }
        }
      }

      // Pass 3: Shortest eBird name that contains the LLM guess as a whole word
      if (bestCommon == null) {
        final wordRegex =
            RegExp(r'\b' + RegExp.escape(lowerRaw) + r'\b');
        for (final entry in scientificToCommon.entries) {
          if (wordRegex.hasMatch(entry.value.toLowerCase())) {
            if (bestCommon == null || entry.value.length < bestCommon.length) {
              bestCommon = entry.value;
              bestSci = entry.key;
            }
          }
        }
      }

      if (bestCommon == null) {
        debugPrint('FAILED to find dictionary match for: "$raw"');
      } else if (!seenScientifics.contains(bestSci)) {
        seenScientifics.add(bestSci!);
        processedSpecies.add(bestCommon);
      }
    }

    return processedSpecies.isEmpty ? ["Unknown Bird"] : processedSpecies;
  }
}
