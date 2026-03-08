import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/geo_region_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/bird_clusterer.dart';
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
  final BirdClusterer _clusterer = const BirdClusterer();
  bool _isInit = false;
  bool _isProcessing = false;
  double _progress = 0.0;
  final List<Observation> _observations = [];
  Observation? _selectedObservation;
  String? _currentlyDisplayedImage;

  // Left panel state
  List<String> _selectedFiles = [];
  final Set<String> _processingFiles = {};
  final Map<String, ExifData> _imageExifData = {};
  // Files grouped into bursts (same order as processing)
  List<List<String>> _fileBursts = [];
  // Cache on-demand HEIC→JPEG conversions so files without observations preview correctly
  final Map<String, String> _convertedHeicPaths = {};
  // Right panel scroll controller — auto-scrolls to matching observation on photo tap
  final ScrollController _observationScrollController = ScrollController();
  // Index of the observation currently being dragged (for visual feedback)
  int? _draggingIndex;

  /// Returns the best displayable (non-HEIC) path for the currently selected image.
  /// Checks processed observations first; falls back to on-demand HEIC conversion.
  Future<String?> _getDisplayPath(String imagePath) async {
    // Prefer the observation's processed JPEG path
    if (_selectedObservation?.imagePath == imagePath) {
      final path = _selectedObservation!.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    }
    try {
      final obs = _observations.firstWhere((o) => o.imagePath == imagePath);
      final path = obs.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    } catch (_) {}

    // If the file itself is not HEIC, return it directly
    if (!imagePath.toLowerCase().endsWith('.heic') &&
        !imagePath.toLowerCase().endsWith('.heif')) {
      return imagePath;
    }

    // Convert HEIC on-demand, caching the result
    if (_convertedHeicPaths.containsKey(imagePath)) {
      return _convertedHeicPaths[imagePath];
    }
    final converted = await ImageConverter.convertToJpegIfNeeded(imagePath);
    if (converted != null && converted != imagePath) {
      _convertedHeicPaths[imagePath] = converted;
      return converted;
    }
    return imagePath;
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

        _observations.clear();
        _selectedObservation = null;
        _currentlyDisplayedImage = null;
        _fileBursts = [];

        _selectedFiles = newFiles;
        _processingFiles.clear();
        _processingFiles.addAll(newFiles);
        _imageExifData.clear();
      });

      // 1) Pre-extract EXIF for all files so we can group them by time
      List<Map<String, dynamic>> fileData = [];
      for (String path in _selectedFiles) {
        try {
          final exif = await ExifService.extractExif(path);
          _imageExifData[path] = exif;
          fileData.add({'path': path, 'exif': exif});
        } catch (_) {
          // If EXIF fails, still include it with a null date
          _imageExifData[path] = ExifData();
          fileData.add({'path': path, 'exif': _imageExifData[path]});
        }
      }

      // Sort files chronologically for burst grouping
      fileData.sort((a, b) {
        final dateA = (a['exif'] as ExifData).dateTime;
        final dateB = (b['exif'] as ExifData).dateTime;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });

      // 2) Group files into bursts (<= 15 seconds apart)
      List<List<String>> bursts = [];
      List<String> currentBurst = [];
      DateTime? lastTime;

      for (var data in fileData) {
        final path = data['path'] as String;
        final date = (data['exif'] as ExifData).dateTime;

        if (date == null) {
          // Files without timestamps get their own burst
          if (currentBurst.isNotEmpty) bursts.add(List.from(currentBurst));
          bursts.add([path]);
          currentBurst.clear();
          lastTime = null;
        } else {
          if (lastTime == null) {
            currentBurst.add(path);
          } else {
            final diff = date.difference(lastTime).inSeconds.abs();
            if (diff <= 15) {
              currentBurst.add(path);
            } else {
              bursts.add(List.from(currentBurst));
              currentBurst = [path];
            }
          }
          lastTime = date;
        }
      }
      if (currentBurst.isNotEmpty) bursts.add(currentBurst);

      // Save burst structure to state so the left panel can render groups
      setState(() {
        _fileBursts = bursts;
        _selectedFiles = bursts.expand((b) => b).toList();
      });

      int totalBursts = bursts.length;
      int totalFiles = _selectedFiles.length;
      int processedCount = 0;

      for (int i = 0; i < totalBursts; i++) {
        final burstFiles = bursts[i];

        // Group crops by their AI predicted species.
        // This ensures the 1 Mute Swan gets its own checklist row and isn't outvoted by 15 Mallards.
        Map<String, BurstGroup> burstGroupsBySpecies = {};

        for (String filePath in burstFiles) {
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
              // Fallback: no birds detected, classify the whole image
              final fallbackBytes = await File(processedPath).readAsBytes();
              final fallbackImg = await compute(img.decodeImage, fallbackBytes);
              if (fallbackImg != null) {
                final speciesList = await _classifier.classifyFile(
                  processedPath,
                  latitude: exifData.latitude,
                  longitude: exifData.longitude,
                  photoDate: exifData.dateTime,
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
                final obs = Observation(
                  imagePath: filePath,
                  displayPath: processedPath,
                  fullImageDisplayPath: processedPath,
                  speciesName: species,
                  possibleSpecies: speciesList,
                  exifData: exifData,
                  count: 1,
                  boundingBoxes: [fullImageBox],
                );
                burstGroupsBySpecies
                    .putIfAbsent(species, () => BurstGroup())
                    .addObservation(obs);
              }
            } else {
              // ── Per-photo cluster-based identification ────────────────────
              // Group similar-size crops into clusters so all Turnstones in a
              // frame get ONE LLM call showing their collective visual evidence.
              // Different-size clusters (e.g. Swan vs. Mallard) stay separate.
              final clusters = _clusterer.cluster(detectedBirds);
              final Map<String, Observation> photoObservations = {};

              for (int ci = 0; ci < clusters.length; ci++) {
                await Future.delayed(Duration.zero);
                final clusterCrops = clusters[ci];
                final clusterBoxes = clusterCrops.map((c) => c.box).toList();

                // One LLM call per cluster — all boxes visible simultaneously
                final speciesList = await _classifier.classifyCluster(
                  processedPath,
                  boxes: clusterBoxes,
                  latitude: exifData.latitude,
                  longitude: exifData.longitude,
                  photoDate: exifData.dateTime,
                );

                final species = speciesList.isNotEmpty
                    ? speciesList.first
                    : 'Unknown';

                if (photoObservations.containsKey(species)) {
                  photoObservations[species]!.count += clusterCrops.length;
                  photoObservations[species]!.boundingBoxes.addAll(
                    clusterBoxes,
                  );
                } else {
                  // Encode the first crop of this cluster as the thumbnail
                  final cropBytes = await compute(
                    img.encodeJpg,
                    clusterCrops.first.croppedImage,
                  );
                  final tempDir = await Directory.systemTemp.createTemp();
                  final filename = filePath.split(Platform.pathSeparator).last;
                  final cropPath = '${tempDir.path}/cluster_${ci}_$filename';
                  await File(cropPath).writeAsBytes(cropBytes);

                  photoObservations[species] = Observation(
                    imagePath: filePath,
                    displayPath: cropPath,
                    fullImageDisplayPath: processedPath,
                    speciesName: species,
                    possibleSpecies: speciesList,
                    exifData: exifData,
                    count: clusterCrops.length,
                    boundingBoxes: clusterBoxes,
                  );
                }
              }

              for (final obs in photoObservations.values) {
                burstGroupsBySpecies
                    .putIfAbsent(obs.speciesName, () => BurstGroup())
                    .addObservation(obs);
              }
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error processing $filePath: $e')),
              );
            }
          }

          processedCount++;
          setState(() {
            _processingFiles.remove(filePath);
            _progress = processedCount / totalFiles;
          });
        } // End of `for (String filePath in burstFiles)`

        // Now that the burst is fully processed, convert BurstGroups to Observations
        if (mounted) {
          setState(() {
            for (var bg in burstGroupsBySpecies.values) {
              if (bg.observations.isNotEmpty) {
                _observations.add(bg.toObservation());
              }
            }
          });
        }
      } // End of `for (int i = 0... bursts.length)`

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
    _observationScrollController.dispose();
    super.dispose();
  }

  /// Scrolls the right-side observation panel to the first observation
  /// that belongs to [imagePath], if one exists.
  void _scrollToObservationForImage(String imagePath) {
    if (!_observationScrollController.hasClients) return;
    final idx = _observations.indexWhere((o) => o.imagePath == imagePath);
    if (idx < 0) return;
    const estimatedItemHeight = 96.0; // approximate Card + margin height
    final target = (idx * estimatedItemHeight).clamp(
      0.0,
      _observationScrollController.position.maxScrollExtent,
    );
    _observationScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// Merges the observation at [fromIdx] into the observation at [intoIdx].
  /// The target keeps its species name; the source's count, boxes, and
  /// source photos are all added.
  void _mergeObservations(int fromIdx, int intoIdx) {
    if (fromIdx == intoIdx) return;
    setState(() {
      final from = _observations[fromIdx];
      final into = _observations[intoIdx];
      into.count += from.count;
      into.boundingBoxes.addAll(from.boundingBoxes);
      // Merge possible species lists (deduplicated)
      for (final s in from.possibleSpecies) {
        if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
      }
      // Merge source images (deduplicated by imagePath)
      final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
      for (final src in from.sourceImages) {
        if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
      }
      // Merge per-photo bounding boxes
      for (final entry in from.boxesByImagePath.entries) {
        into.boxesByImagePath
            .putIfAbsent(entry.key, () => [])
            .addAll(entry.value);
      }
      _observations.removeAt(fromIdx);
      if (_selectedObservation == from) _selectedObservation = into;
    });
  }

  Widget _buildFileListPanel() {
    // Fall back to a flat list if bursts haven't been computed yet
    final bursts = _fileBursts.isNotEmpty
        ? _fileBursts
        : _selectedFiles.map((f) => [f]).toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: bursts.length,
      itemBuilder: (context, burstIndex) {
        final burstFiles = bursts[burstIndex];
        final isBurst = burstFiles.length > 1;

        // Get the timestamp from the first file in the burst
        final firstFile = burstFiles.first;
        final firstExif = _imageExifData[firstFile];
        final timestamp = firstExif?.dateTime;
        final timeLabel = timestamp != null
            ? '${timestamp.hour.toString().padLeft(2, '0')}:'
                  '${timestamp.minute.toString().padLeft(2, '0')}:'
                  '${timestamp.second.toString().padLeft(2, '0')}'
            : 'Unknown time';
        final dateLabel = timestamp != null
            ? '${timestamp.year}-'
                  '${timestamp.month.toString().padLeft(2, '0')}-'
                  '${timestamp.day.toString().padLeft(2, '0')}'
            : '';

        Widget fileTile(String file) {
          final isProcessing = _processingFiles.contains(file);
          final filename = file.split(Platform.pathSeparator).last;
          final isSelected = _currentlyDisplayedImage == file;

          // Total individuals identified across all observations that include this photo
          final individualCount = _observations
              .where((o) => o.sourceImages.any((s) => s.imagePath == file))
              .fold<int>(0, (sum, o) => sum + o.count);

          return InkWell(
            onTap: () {
              setState(() {
                _currentlyDisplayedImage = file;
                _selectedObservation = _observations
                    .where((o) => o.imagePath == file)
                    .firstOrNull;
              });
              // Scroll the right panel to the first matching observation
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _scrollToObservationForImage(file),
              );
            },
            child: Container(
              color: isSelected
                  ? Colors.blue.withValues(alpha: 0.12)
                  : Colors.transparent,
              padding: EdgeInsets.only(
                left: isBurst ? 24 : 12,
                right: 8,
                top: 6,
                bottom: 6,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      filename,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (!isProcessing && individualCount > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '$individualCount',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                  if (isProcessing)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    const Icon(
                      Icons.check_circle,
                      color: Colors.green,
                      size: 12,
                    ),
                ],
              ),
            ),
          );
        }

        if (!isBurst) {
          // Single photo — show with a minimal timestamp row
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (burstIndex == 0 || dateLabel.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time,
                        size: 11,
                        color: Theme.of(context).hintColor,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '$dateLabel  $timeLabel',
                        style: TextStyle(
                          fontSize: 10,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ),
                ),
              fileTile(firstFile),
              const Divider(height: 1, indent: 12, endIndent: 8),
            ],
          );
        }

        // Multi-photo burst: show a bold header bar
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 4),
              child: Row(
                children: [
                  Icon(
                    Icons.burst_mode,
                    size: 13,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      '$dateLabel  $timeLabel',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                  Text(
                    '${burstFiles.length} photos',
                    style: TextStyle(
                      fontSize: 10,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
            ...burstFiles.map(fileTile),
            const Divider(height: 1, indent: 12, endIndent: 8),
          ],
        );
      },
    );
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
                    child: _buildFileListPanel(),
                  ),
                ),
                const VerticalDivider(width: 1),

                _buildCenterPane(),

                const VerticalDivider(width: 1),
                // Right side: Observations specific to this image or all images
                Expanded(
                  flex: 1,
                  child: ListView.builder(
                    controller: _observationScrollController,
                    itemCount: _observations.length,
                    itemBuilder: (context, index) {
                      final obs = _observations[index];
                      final isSelected = _selectedObservation == obs;
                      final isDragging = _draggingIndex == index;

                      Widget card = Opacity(
                        opacity: isDragging ? 0.4 : 1.0,
                        child: Card(
                          shape: const SuperellipseBorder(m: 200.0, n: 20.0),
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          color: isSelected
                              ? Colors.blue.withValues(alpha: 0.1)
                              : null,
                          child: ListTile(
                            shape: const SuperellipseBorder(m: 200.0, n: 20.0),
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
                                      });
                                    },
                                    itemBuilder: (BuildContext context) {
                                      return obs.possibleSpecies
                                          .map(
                                            (String choice) =>
                                                PopupMenuItem<String>(
                                                  value: choice,
                                                  child: Text(choice),
                                                ),
                                          )
                                          .toList();
                                    },
                                  ),
                              ],
                            ),
                            subtitle: Text(
                              'Date: ${obs.exifData.dateTime?.toLocal().toString().split(".")[0] ?? "?"}\nLat: ${obs.exifData.latitude?.toStringAsFixed(4) ?? "?"}, Lon: ${obs.exifData.longitude?.toStringAsFixed(4) ?? "?"}',
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
                        ),
                      );

                      // Wrap in DragTarget first (inner), then Draggable (outer)
                      return DragTarget<int>(
                        onWillAcceptWithDetails: (details) =>
                            details.data != index,
                        onAcceptWithDetails: (details) {
                          _mergeObservations(details.data, index);
                        },
                        builder: (context, candidateData, rejectedData) {
                          final isHovered = candidateData.isNotEmpty;
                          return Draggable<int>(
                            data: index,
                            onDragStarted: () =>
                                setState(() => _draggingIndex = index),
                            onDragEnd: (_) =>
                                setState(() => _draggingIndex = null),
                            onDraggableCanceled: (velocity, offset) =>
                                setState(() => _draggingIndex = null),
                            feedback: Material(
                              elevation: 6,
                              borderRadius: BorderRadius.circular(12),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 320,
                                ),
                                child: Opacity(
                                  opacity: 0.85,
                                  child: Card(
                                    margin: EdgeInsets.zero,
                                    child: ListTile(
                                      leading: obs.displayPath != null
                                          ? Image.file(
                                              File(obs.displayPath!),
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                            )
                                          : const Icon(Icons.image),
                                      title: Text(
                                        obs.speciesName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      trailing: Text(
                                        '×${obs.count}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            childWhenDragging: const SizedBox.shrink(),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: isHovered
                                    ? Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        width: 2,
                                      )
                                    : null,
                                boxShadow: isHovered
                                    ? [
                                        BoxShadow(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary
                                              .withValues(alpha: 0.3),
                                          blurRadius: 8,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: card,
                            ),
                          );
                        },
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

  // ─────────────────── Center pane ─────────────────────────────────────────

  Widget _buildCenterPane() {
    // Determine which sources to show:
    // • When an observation with multiple source photos is selected → show all
    // • Otherwise fall back to the currently displayed image (left-panel tap)
    final sources =
        _selectedObservation != null &&
            _selectedObservation!.sourceImages.length > 1
        ? _selectedObservation!.sourceImages
        : (_currentlyDisplayedImage != null
              ? <SourceImage>[
                  (
                    imagePath: _currentlyDisplayedImage!,
                    fullImageDisplayPath:
                        _selectedObservation?.fullImageDisplayPath,
                  ),
                ]
              : null);

    if (sources == null) {
      return const Expanded(
        flex: 2,
        child: Center(child: Text('Select photos to begin')),
      );
    }

    final isMulti = sources.length > 1;
    final obs = _selectedObservation;

    Widget photoCard(SourceImage src) {
      final rawPath = src.imagePath;
      final resolvedFuture =
          src.fullImageDisplayPath != null &&
              !src.fullImageDisplayPath!.toLowerCase().endsWith('.heic')
          ? Future.value(src.fullImageDisplayPath)
          : _getDisplayPath(rawPath);

      final filename = rawPath.split('/').last.split('\\').last;
      final exif = _imageExifData[rawPath];
      final lat = exif?.latitude;
      final lon = exif?.longitude;

      // Shared: image + bounding-box overlay for a single resolved photo
      Widget buildStack(String displayPath, Size imgSize) {
        final photoBoxes =
            obs?.boxesByImagePath[rawPath] ??
            (obs?.imagePath == rawPath ? obs!.boundingBoxes : const []);
        return Stack(
          alignment: Alignment.center,
          fit: isMulti ? StackFit.expand : StackFit.loose,
          children: [
            Image.file(
              File(displayPath),
              width: double.infinity,
              fit: isMulti ? BoxFit.fill : BoxFit.contain,
            ),
            if (obs != null && photoBoxes.isNotEmpty)
              Positioned.fill(
                child: CustomPaint(
                  painter: _BoundingBoxPainter(
                    boxes: photoBoxes,
                    imageSize: imgSize,
                  ),
                ),
              ),
          ],
        );
      }

      // Caption strip shown below each image
      List<Widget> captions = [
        const SizedBox(height: 4),
        if (lat != null && lon != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.location_on, size: 12, color: Colors.blueGrey),
              const SizedBox(width: 3),
              Flexible(
                child: SelectableText(
                  GeoRegionService.describe(lat, lon),
                  style: const TextStyle(fontSize: 11, color: Colors.blueGrey),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        const SizedBox(height: 2),
        SelectableText(
          filename,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: isMulti ? 12 : 14,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ];

      if (isMulti) {
        // Multi-photo mode: let each image display at its natural aspect ratio
        // (no fixed height, no clipping). InteractiveViewer omitted because the
        // outer ListView handles scrolling.
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<String?>(
              future: resolvedFuture,
              builder: (context, pathSnap) {
                final displayPath = pathSnap.data;
                if (displayPath == null ||
                    displayPath.toLowerCase().endsWith('.heic')) {
                  return const SizedBox(
                    height: 120,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return FutureBuilder<Size>(
                  future: _getImageSize(displayPath),
                  builder: (context, sizeSnap) {
                    if (!sizeSnap.hasData) {
                      return const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final imgSize = sizeSnap.data!;
                    return AspectRatio(
                      aspectRatio: imgSize.width / imgSize.height,
                      child: buildStack(displayPath, imgSize),
                    );
                  },
                );
              },
            ),
            ...captions,
          ],
        );
      }

      // Single-photo mode: fill the pane with an interactive viewer
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: InteractiveViewer(
              child: LayoutBuilder(
                builder: (context, constraints) => FutureBuilder<String?>(
                  future: resolvedFuture,
                  builder: (context, pathSnap) {
                    final displayPath = pathSnap.data;
                    if (displayPath == null ||
                        displayPath.toLowerCase().endsWith('.heic')) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    return FutureBuilder<Size>(
                      future: _getImageSize(displayPath),
                      builder: (context, sizeSnap) {
                        if (!sizeSnap.hasData) {
                          return const Center(
                            child: CircularProgressIndicator(),
                          );
                        }
                        return buildStack(displayPath, sizeSnap.data!);
                      },
                    );
                  },
                ),
              ),
            ),
          ),
          ...captions,
        ],
      );
    }

    if (!isMulti) {
      // Single-source: full-pane viewer (original behavior)
      return Expanded(
        flex: 2,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: photoCard(sources.first),
        ),
      );
    }

    // Multi-source: vertical scrollable strip
    return Expanded(
      flex: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                const Icon(
                  Icons.photo_library,
                  size: 14,
                  color: Colors.blueGrey,
                ),
                const SizedBox(width: 6),
                Text(
                  '${sources.length} photos',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.blueGrey,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: sources.length,
              separatorBuilder: (context, index) => const Divider(height: 16),
              itemBuilder: (context, i) => photoCard(sources[i]),
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

class SuperellipseBorder extends ShapeBorder {
  final double m;
  final double n;

  const SuperellipseBorder({this.m = 200.0, this.n = 20.0});

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.zero;

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _getPath(rect);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _getPath(rect);

  Path _getPath(Rect rect) {
    final Path path = Path();
    final double a = rect.width / 2.0;
    final double b = rect.height / 2.0;
    final double centerX = rect.center.dx;
    final double centerY = rect.center.dy;

    const int segments = 100;
    for (int i = 0; i <= segments; i++) {
      final double t = (i / segments) * 2 * pi;
      double cost = cos(t);
      double sint = sin(t);

      // Parametric formulas for a superellipse: |x/a|^m + |y/b|^n = 1
      double px = centerX + a * cost.sign * pow(cost.abs(), 2 / m);
      double py = centerY + b * sint.sign * pow(sint.abs(), 2 / n);

      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    path.close();
    return path;
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {}

  @override
  ShapeBorder scale(double t) {
    return SuperellipseBorder(m: m, n: n);
  }
}
