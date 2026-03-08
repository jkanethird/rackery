import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/geo_region_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/csv_service.dart';
import 'package:ebird_generator/services/image_converter.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:ebird_generator/ui/sine_wave_progress.dart';
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

  // Left panel state
  List<String> _selectedFiles = [];
  final Set<String> _processingFiles = {};

  String? get _displayImagePath {
    if (_currentlyDisplayedImage == null) return null;

    // Prefer the observation's processed JPEG path (works for both HEIC and JPEG sources)
    // First, check the selected observation
    if (_selectedObservation != null) {
      final path = _selectedObservation!.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    }

    // Then check any observation for the current image
    try {
      final obs = _observations.firstWhere(
        (o) => o.imagePath == _currentlyDisplayedImage,
      );
      final path = obs.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    } catch (_) {}

    // Fall back to the original path (could be HEIC or JPEG)
    return _currentlyDisplayedImage;
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
      final newFilesList = result.files.toList();
      // Sort files by size ascending so the quickest ones process first
      newFilesList.sort((a, b) => a.size.compareTo(b.size));
      final newFiles = newFilesList.map((f) => f.path!).toList();
      setState(() {
        _isProcessing = true;
        _progress = 0.0;

        // Add new files to the list without clearing previous ones if you wanted accumulation,
        // but to match previous behavior of totally resetting, we wipe the slate:
        _observations.clear();
        _selectedObservation = null;
        _currentlyDisplayedImage = null;

        _selectedFiles = newFiles;
        _processingFiles.clear();
        _processingFiles.addAll(newFiles);
      });

      int total = _selectedFiles.length;
      for (int i = 0; i < total; i++) {
        final filePath = _selectedFiles[i];
        try {
          // Convert to JPEG if HEIC/HEIF
          final processedPath =
              await ImageConverter.convertToJpegIfNeeded(filePath) ?? filePath;

          // Extract EXIF from original file
          final exifData = await ExifService.extractExif(filePath);

          // Detect all birds in the image
          List<BirdCrop> detectedBirds = await _detector.detectAndCrop(
            processedPath,
          );

          if (detectedBirds.isEmpty) {
            // Fallback: no birds detected, classify the whole image
            final fallbackBytes = await File(processedPath).readAsBytes();
            final fallbackImg = await compute(img.decodeImage, fallbackBytes);
            if (fallbackImg != null) {
              final speciesList = await _classifier.classifyFile(
                processedPath,
                latitude: exifData.latitude,
                longitude: exifData.longitude,
              );
              final species = speciesList.isNotEmpty
                  ? speciesList.first
                  : "Unknown";
              // Use full image as coverage box
              final fullImageBox = Rectangle<int>(
                0,
                0,
                fallbackImg.width,
                fallbackImg.height,
              );
              _observations.add(
                Observation(
                  imagePath: filePath,
                  displayPath: processedPath,
                  fullImageDisplayPath: processedPath,
                  speciesName: species,
                  possibleSpecies: speciesList,
                  exifData: exifData,
                  count: 1,
                  boundingBoxes: [fullImageBox],
                ),
              );
            }
          } else {
            // Track aggregated observations for this specific photo
            Map<String, Observation> photoObservations = {};

            // Classify each detected bird crop
            for (int cropIdx = 0; cropIdx < detectedBirds.length; cropIdx++) {
              await Future.delayed(Duration.zero);
              final cropInfo = detectedBirds[cropIdx];
              // Send the FULL image with bounding box context - far more accurate
              // than sending a tiny crop that lacks visual detail and context
              final speciesList = await _classifier.classifyFile(
                processedPath,
                box: cropInfo.box,
                latitude: exifData.latitude,
                longitude: exifData.longitude,
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
                final cropBytes = await compute(
                  img.encodeJpg,
                  cropInfo.croppedImage,
                );
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
        // No closing brace needed here as we removed the `if (filePath != null)` check earlier

        setState(() {
          _processingFiles.remove(filePath);
          _progress = (i + 1) / total;
        });
      }

      // Final state update
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
                        const SizedBox(height: 8),
                        SineWaveProgressIndicator(value: _progress),
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
                // Far Left side: List of selected photos
                Expanded(
                  flex: 1,
                  child: Container(
                    color: Theme.of(context).cardColor,
                    child: ListView.builder(
                      itemCount: _selectedFiles.length,
                      itemBuilder: (context, index) {
                        final file = _selectedFiles[index];
                        final isProcessing = _processingFiles.contains(file);
                        final filename = file
                            .split(Platform.pathSeparator)
                            .last;
                        final isSelected = _currentlyDisplayedImage == file;

                        return ListTile(
                          selected: isSelected,
                          selectedTileColor: Colors.blue.withValues(alpha: 0.1),
                          title: Text(
                            filename,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: isSelected
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                          trailing: isProcessing
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 16,
                                ),
                          onTap: () {
                            setState(() {
                              _currentlyDisplayedImage = file;
                              // Try to find the associated observation if it exists to show boxes
                              _selectedObservation = _observations
                                  .where((o) => o.imagePath == file)
                                  .firstOrNull;
                            });
                          },
                        );
                      },
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),

                // Center side: Image with bounding boxes
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
                                              child:
                                                  CircularProgressIndicator(),
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
                                              if (_selectedObservation !=
                                                      null &&
                                                  _selectedObservation!
                                                          .imagePath ==
                                                      _currentlyDisplayedImage &&
                                                  _selectedObservation!
                                                      .boundingBoxes
                                                      .isNotEmpty)
                                                Positioned.fill(
                                                  child: CustomPaint(
                                                    painter: _BoundingBoxPainter(
                                                      boxes:
                                                          _selectedObservation!
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
                              const SizedBox(height: 8),
                              // Geographic location from EXIF GPS data
                              Builder(
                                builder: (context) {
                                  final obs =
                                      _selectedObservation ??
                                      _observations
                                          .where(
                                            (o) =>
                                                o.imagePath ==
                                                _currentlyDisplayedImage,
                                          )
                                          .firstOrNull;
                                  final lat = obs?.exifData.latitude;
                                  final lon = obs?.exifData.longitude;
                                  if (lat == null || lon == null) {
                                    return const SizedBox.shrink();
                                  }
                                  return Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(
                                        Icons.location_on,
                                        size: 14,
                                        color: Colors.blueGrey,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: SelectableText(
                                          GeoRegionService.describe(lat, lon),
                                          style: const TextStyle(
                                            fontSize: 13,
                                            color: Colors.blueGrey,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                _currentlyDisplayedImage!
                                    .split('/')
                                    .last
                                    .split('\\')
                                    .last,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                textAlign: TextAlign.center,
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
                    }, // end itemBuilder
                  ), // end ListView.builder
                ), // end right Expanded
              ], // end Row children
            ), // end Row
          ), // end outer Expanded
        ], // end Column children
      ), // end Column
    ); // end Scaffold
  } // end build

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
