import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/csv_service.dart';
import 'package:ebird_generator/services/image_converter.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:image/image.dart' as img;

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final BirdClassifier _classifier = BirdClassifier();
  final BirdDetector _detector = BirdDetector();
  bool _isInit = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  final List<Observation> _observations = [];

  @override
  void initState() {
    super.initState();
    _initClassifier();
  }

  Future<void> _initClassifier() async {
    try {
      await _classifier.init();
      await _detector.init();
      setState(() {
        _isInit = true;
      });
    } catch (e) {
      debugPrint("Error initializing classifier: $e");
    }
  }

  Future<void> _selectAndProcessPhotos() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: [
        'jpg',
        'jpeg',
        'png',
        'heic',
        'heif',
        'JPG',
        'JPEG',
        'PNG',
        'HEIC',
        'HEIF',
      ],
    );

    if (result != null) {
      setState(() {
        _isProcessing = true;
        _progress = 0.0;
        _observations.clear();
      });

      int total = result.files.length;
      for (int i = 0; i < total; i++) {
        final filePath = result.files[i].path;
        if (filePath != null) {
          try {
            // Convert to JPEG if HEIC/HEIF
            final processedPath =
                await ImageConverter.convertToJpegIfNeeded(filePath) ??
                filePath;

            // Extract EXIF from original file
            final exifData = await ExifService.extractExif(filePath);

            // Detect all birds in the image
            List<BirdCrop> detectedBirds = await _detector.detectAndCrop(
              processedPath,
            );

            if (detectedBirds.isEmpty) {
              // Fallback if no specific birds detected, classify the whole image
              final fallbackBytes = await File(processedPath).readAsBytes();
              final fallbackImg = img.decodeImage(fallbackBytes);
              if (fallbackImg != null) {
                final species = await _classifier.classify(fallbackImg);
                _observations.add(
                  Observation(
                    imagePath: filePath,
                    displayPath: processedPath,
                    speciesName: species ?? "Unknown",
                    exifData: exifData,
                    count: 1,
                  ),
                );
              }
            } else {
              // Classify each detected bird crop
              for (int cropIdx = 0; cropIdx < detectedBirds.length; cropIdx++) {
                final cropInfo = detectedBirds[cropIdx];
                final species = await _classifier.classify(
                  cropInfo.croppedImage,
                );

                // Save the crop to a temporary file so the UI can display the exact bird
                final cropBytes = img.encodeJpg(cropInfo.croppedImage);
                final tempDir = await Directory.systemTemp.createTemp();
                final filename = filePath.split(Platform.pathSeparator).last;
                final cropPath = '${tempDir.path}/crop_${cropIdx}_$filename';
                await File(cropPath).writeAsBytes(cropBytes);

                _observations.add(
                  Observation(
                    imagePath: filePath,
                    displayPath: cropPath,
                    speciesName: species ?? "Unknown",
                    exifData: exifData,
                    count: 1, // Keep initial count at 1 per discrete detection
                  ),
                );
              }
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error processing $filePath: $e')),
              );
            }
          }
        }
        setState(() {
          _progress = (i + 1) / total;
        });
      }

      setState(() {
        _isProcessing = false;
      });
    }
  }

  Future<void> _exportCsv() async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'ebird_checklist.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );

    if (outputFile != null) {
      if (!outputFile.endsWith('.csv')) {
        outputFile += '.csv';
      }
      await CsvService.generateEbirdCsv(_observations, outputFile);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('CSV exported to $outputFile')));
      }
    }
  }

  @override
  void dispose() {
    _classifier.dispose();
    _detector.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInit) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text("eBird Checklist Generator"),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _observations.isEmpty || _isProcessing
                ? null
                : _exportCsv,
            tooltip: "Export CSV",
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isProcessing ? null : _selectAndProcessPhotos,
                  icon: const Icon(Icons.photo_library),
                  label: const Text("Select Photos"),
                ),
                const SizedBox(width: 16),
                if (_isProcessing)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Processing images..."),
                        const SizedBox(height: 4),
                        LinearProgressIndicator(value: _progress),
                      ],
                    ),
                  )
                else
                  Expanded(
                    child: Text(
                      _observations.isEmpty
                          ? "No photos selected"
                          : "${_observations.length} observations generated",
                      style: const TextStyle(fontStyle: FontStyle.italic),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _observations.length,
              itemBuilder: (context, index) {
                final obs = _observations[index];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: ListTile(
                    leading: Image.file(
                      File(obs.displayPath ?? obs.imagePath),
                      width: 50,
                      height: 50,
                      fit: BoxFit.cover,
                    ),
                    title: TextFormField(
                      initialValue: obs.speciesName,
                      decoration: const InputDecoration(labelText: "Species"),
                      onChanged: (val) {
                        obs.speciesName = val;
                      },
                    ),
                    subtitle: Text(
                      "Date: ${obs.exifData.dateTime?.toLocal().toString().split('.')[0] ?? '?'}\nLat: ${obs.exifData.latitude?.toStringAsFixed(4) ?? '?'}, Lon: ${obs.exifData.longitude?.toStringAsFixed(4) ?? '?'}",
                    ),
                    trailing: SizedBox(
                      width: 60,
                      child: TextFormField(
                        initialValue: obs.count.toString(),
                        decoration: const InputDecoration(labelText: "Count"),
                        keyboardType: TextInputType.number,
                        onChanged: (val) {
                          obs.count = int.tryParse(val) ?? 1;
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
