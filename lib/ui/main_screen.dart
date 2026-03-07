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
import 'dart:math';

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
  Observation? _selectedObservation;
  String? _currentlyDisplayedImage;

  String? get _displayImagePath {
    if (_selectedObservation != null &&
        _selectedObservation!.fullImageDisplayPath != null) {
      return _selectedObservation!.fullImageDisplayPath;
    }
    if (_currentlyDisplayedImage == null) return null;

    // Find the first observation for this image to get its processed JPEG path
    try {
      final obs = _observations.firstWhere(
        (o) => o.imagePath == _currentlyDisplayedImage,
      );
      return obs.fullImageDisplayPath ?? _currentlyDisplayedImage;
    } catch (_) {
      // Fallback to original path if no observations yet (e.g. during processing)
      return _currentlyDisplayedImage;
    }
  }

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
        _selectedObservation = null;
        _currentlyDisplayedImage = null;
      });

      int total = result.files.length;
      for (int i = 0; i < total; i++) {
        final filePath = result.files[i].path;
        if (filePath != null) {
          setState(() {
            _currentlyDisplayedImage = filePath; // Update left side immediately
          });
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
                final speciesList = await _classifier.classify(fallbackImg);
                final species = speciesList.isNotEmpty
                    ? speciesList.first
                    : "Unknown";
                _observations.add(
                  Observation(
                    imagePath: filePath,
                    displayPath: processedPath,
                    fullImageDisplayPath: processedPath,
                    speciesName: species,
                    possibleSpecies: speciesList,
                    exifData: exifData,
                    count: 1,
                  ),
                );
              }
            } else {
              // Track aggregated observations for this specific photo
              Map<String, Observation> photoObservations = {};

              // Classify each detected bird crop
              for (int cropIdx = 0; cropIdx < detectedBirds.length; cropIdx++) {
                final cropInfo = detectedBirds[cropIdx];
                final speciesList = await _classifier.classify(
                  cropInfo.croppedImage,
                );
                final species = speciesList.isNotEmpty
                    ? speciesList.first
                    : "Unknown";

                if (photoObservations.containsKey(species)) {
                  // Aggregate
                  photoObservations[species]!.count += 1;
                  photoObservations[species]!.boundingBoxes.add(cropInfo.box);
                } else {
                  // Save a single representative crop for the UI icon
                  final cropBytes = img.encodeJpg(cropInfo.croppedImage);
                  final tempDir = await Directory.systemTemp.createTemp();
                  final filename = filePath.split(Platform.pathSeparator).last;
                  final cropPath = '${tempDir.path}/crop_${cropIdx}_$filename';
                  await File(cropPath).writeAsBytes(cropBytes);

                  photoObservations[species] = Observation(
                    imagePath: filePath,
                    displayPath: cropPath,
                    fullImageDisplayPath: processedPath,
                    speciesName: species,
                    possibleSpecies: speciesList,
                    exifData: exifData,
                    count: 1,
                    boundingBoxes: [cropInfo.box],
                  );
                }
              }

              _observations.addAll(photoObservations.values);
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
        if (_observations.isNotEmpty) {
          _selectedObservation = _observations.first;
          _currentlyDisplayedImage = _selectedObservation!.imagePath;
        }
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
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left side: Image with bounding boxes
                Expanded(
                  flex: 2,
                  child: _currentlyDisplayedImage == null
                      ? const Center(child: Text("Select photos to begin"))
                      : Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              Expanded(
                                child: InteractiveViewer(
                                  child: LayoutBuilder(
                                    builder: (context, constraints) {
                                      final displayPath = _displayImagePath!;
                                      if (displayPath.toLowerCase().endsWith(
                                        '.heic',
                                      )) {
                                        return const Center(
                                          child: CircularProgressIndicator(),
                                        );
                                      }
                                      return FutureBuilder<Size>(
                                        future: _getImageSize(displayPath),
                                        builder: (context, snapshot) {
                                          if (!snapshot.hasData) {
                                            return const Center(
                                              child: CircularProgressIndicator(),
                                            );
                                          }

                                          // Scale logic to match rendered image to original size for Painter
                                          final imgSize = snapshot.data!;

                                          return Stack(
                                            alignment: Alignment.center,
                                            fit: StackFit.loose,
                                            children: [
                                              Image.file(
                                                File(displayPath),
                                                fit: BoxFit.contain,
                                              ),
                                              if (_selectedObservation != null &&
                                                  _selectedObservation!.imagePath ==
                                                      _currentlyDisplayedImage &&
                                                  _selectedObservation!
                                                      .boundingBoxes
                                                      .isNotEmpty)
                                                Positioned.fill(
                                                  child: CustomPaint(
                                                    painter: _BoundingBoxPainter(
                                                      boxes: _selectedObservation!
                                                          .boundingBoxes,
                                                      imageSize: imgSize,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          );
                                        },
                                      );
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _currentlyDisplayedImage!.split('/').last.split('\\').last,
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                ),
                const VerticalDivider(width: 1),
                // Right side: Observations specific to this image or all images
                Expanded(
                  flex: 1,
                  child: ListView.builder(
                    itemCount: _observations.length,
                    itemBuilder: (context, index) {
                      final obs = _observations[index];
                      // Optional: Filter right side to only show observations for _currentlyDisplayedImage
                      // For now, let's show all and highlight the selected one
                      final isSelected = _selectedObservation == obs;

                      return Card(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        color: isSelected
                            ? Colors.blue.withValues(alpha: 0.1)
                            : null,
                        child: ListTile(
                          onTap: () {
                            setState(() {
                              _selectedObservation = obs;
                              _currentlyDisplayedImage = obs.imagePath;
                            });
                          },
                          leading: obs.displayPath != null
                              ? Image.file(
                                  File(obs.displayPath!),
                                  width: 50,
                                  height: 50,
                                  fit: BoxFit.cover,
                                )
                              : const Icon(Icons.image),
                          title: Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  key: ValueKey(
                                    "${obs.imagePath}_${obs.speciesName}",
                                  ),
                                  initialValue: obs.speciesName,
                                  decoration: const InputDecoration(
                                    labelText: "Species",
                                  ),
                                  onChanged: (val) {
                                    obs.speciesName = val;
                                  },
                                ),
                              ),
                              if (obs.possibleSpecies.length > 1)
                                PopupMenuButton<String>(
                                  icon: const Icon(Icons.arrow_drop_down),
                                  tooltip: "AI Alternatives",
                                  onSelected: (String value) {
                                    setState(() {
                                      obs.speciesName = value;
                                      // Note: changing species name doesn't re-aggregate them,
                                      // but updates this specific entry's name for the CSV export.
                                    });
                                  },
                                  itemBuilder: (BuildContext context) {
                                    return obs.possibleSpecies.map((
                                      String choice,
                                    ) {
                                      return PopupMenuItem<String>(
                                        value: choice,
                                        child: Text(choice),
                                      );
                                    }).toList();
                                  },
                                ),
                            ],
                          ),
                          subtitle: Text(
                            "Date: ${obs.exifData.dateTime?.toLocal().toString().split('.')[0] ?? '?'}\nLat: ${obs.exifData.latitude?.toStringAsFixed(4) ?? '?'}, Lon: ${obs.exifData.longitude?.toStringAsFixed(4) ?? '?'}",
                          ),
                          trailing: SizedBox(
                            width: 60,
                            child: TextFormField(
                              initialValue: obs.count.toString(),
                              decoration: const InputDecoration(
                                labelText: "Count",
                              ),
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
          ),
        ],
      ),
    );
  }

  Future<Size> _getImageSize(String path) async {
    final file = File(path);
    final bytes = await file.readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    return Size(decoded.width.toDouble(), decoded.height.toDouble());
  }
}

class _BoundingBoxPainter extends CustomPainter {
  final List<Rectangle<int>> boxes;
  final Size imageSize;

  _BoundingBoxPainter({required this.boxes, required this.imageSize});

  @override
  void paint(Canvas canvas, Size size) {
    if (boxes.isEmpty) return;

    final paint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    // Calculate scaling factors between rendered layout size and original image size
    // BoxFit.contain will scale the image uniformly until it hits the layout boundary
    double scaleX = size.width / imageSize.width;
    double scaleY = size.height / imageSize.height;
    double scale = min(scaleX, scaleY);

    // Calculate offsets if the image is centered
    double dx = (size.width - (imageSize.width * scale)) / 2.0;
    double dy = (size.height - (imageSize.height * scale)) / 2.0;

    for (var box in boxes) {
      final rect = Rect.fromLTWH(
        (box.left * scale) + dx,
        (box.top * scale) + dy,
        box.width * scale,
        box.height * scale,
      );
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _BoundingBoxPainter oldDelegate) {
    return oldDelegate.boxes != boxes || oldDelegate.imageSize != imageSize;
  }
}
