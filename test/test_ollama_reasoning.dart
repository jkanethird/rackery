// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

void main() async {
  final fileBytes = await File(
    '/tmp/converted_IMG_3835.HEIC.jpg',
  ).readAsBytes();
  final originalImage = img.decodeImage(fileBytes);
  if (originalImage == null) return;

  final jpgBytes = img.encodeJpg(originalImage, quality: 90);
  final base64Image = base64Encode(jpgBytes);

  final prompt =
      'You are an expert ornithologist helping build an eBird checklist. '
      'Carefully examine this photograph.\n'
      'Identify the bird species using visible features: body shape, plumage color '
      'and pattern, beak shape, leg color, size relative to surroundings, and habitat.\n'
      'Explain your reasoning step by step, and then provide your best guess for the species.';

  final response = await http.post(
    Uri.parse('http://localhost:11434/api/generate'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'model': 'llava:13b',
      'prompt': prompt,
      'images': [base64Image],
      'stream': false,
      'options': {'temperature': 0.2, 'num_predict': 512},
    }),
  );

  if (response.statusCode == 200) {
    final data = jsonDecode(response.body);
    print(data['response']);
  } else {
    print("Error: \${response.statusCode}");
  }
}
