import 'dart:convert';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:ebird_generator/services/bird_names.dart';

class BirdClassifier {
  // No initialization needed for local REST API other than ensuring it exists
  Future<void> init() async {
    // We could ping http://localhost:11434 to check if Ollama is running here,
    // but we'll assume it's running for now and handle connection errors in classify().
  }

  Future<List<String>> classify(img.Image image) async {
    try {
      // Encode the image to base64
      final jpgBytes = img.encodeJpg(image);
      final base64Image = base64Encode(jpgBytes);

      final prompt = """You are an expert ornithologist identifying birds for an eBird checklist.
Analyze this cropped image and identify the bird species. It may be a whole bird or just a part of it.
Return ONLY a valid JSON array of strings containing your top 1 to 5 highly confident guesses, formatted exactly like: ["Common Name (Scientific name)", "Alternative Name (Scientific name)"].
If you cannot identify any bird, return ["Unknown Bird"].
OUTPUT NOTHING BUT THE JSON ARRAY. NO MARKDOWN. NO CONVERSATION.""";

      final response = await http.post(
        Uri.parse('http://localhost:11434/api/generate'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': 'llava',
          'prompt': prompt,
          'images': [base64Image],
          'stream': false,
          'options': {
             // Keep the temperature low for more deterministic classification
            'temperature': 0.1,
          }
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        String responseText = data['response'].toString().trim();

        // Strip markdown code block if the LLM provided it anyway
        if (responseText.startsWith('```json')) {
            responseText = responseText.substring(7);
            if (responseText.endsWith('```')) {
                responseText = responseText.substring(0, responseText.length - 3);
            }
        } else if (responseText.startsWith('```')) {
            responseText = responseText.substring(3);
            if (responseText.endsWith('```')) {
                responseText = responseText.substring(0, responseText.length - 3);
            }
        }
        responseText = responseText.trim();

        // Fallback robust json array extraction
        final regex = RegExp(r'\[.*\]', dotAll: true);
        final match = regex.firstMatch(responseText);
        if (match != null) {
            responseText = match.group(0)!;
        }

        try {
          final List<dynamic> jsonList = jsonDecode(responseText);
          List<String> rawSpeciesList = jsonList.map((e) => e.toString()).toList();
          
          if (rawSpeciesList.isEmpty) return ["Unknown Bird"];
          
          List<String> processedSpecies = [];
          Set<String> seenScientifics = {};
          
          for (String raw in rawSpeciesList) {
             if (raw == "Unknown Bird") continue;
             
             // Extract scientific name inside parentheses
             final sciRegex = RegExp(r'\((.*?)\)');
             final sciMatch = sciRegex.firstMatch(raw);
             
             if (sciMatch != null) {
                 String sciName = sciMatch.group(1)!;
                 // Deduplicate by scientific name
                 if (seenScientifics.contains(sciName)) continue;
                 seenScientifics.add(sciName);
                 
                 // Standardize common name using our dictionary if available
                 String commonName = scientificToCommon[sciName] ?? raw.split('(')[0].trim();
                 processedSpecies.add("$commonName ($sciName)");
             } else {
                 if (!processedSpecies.contains(raw)) processedSpecies.add(raw);
             }
          }
          
          if (processedSpecies.isEmpty) return ["Unknown Bird"];
          return processedSpecies;
          
        } catch (e) {
          print("Failed to parse LLM JSON response: $responseText");
          return ["Unknown Bird"];
        }
      } else {
        print("Ollama API Error: ${response.statusCode} - ${response.body}");
        return ["Unknown Bird (Ollama Error)"];
      }
    } catch (e) {
      print("Error classifying with Ollama: $e");
      return ["Unknown Bird (Connection Error)"];
    }
  }

  void dispose() {
    // Nothing to dispose for HTTP client approach
  }
}
