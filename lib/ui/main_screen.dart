import 'widgets/observation_card.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

const _kLastPickerDirKey = 'last_picker_directory';

class DragData {
  final int obsIndex;
  final List<int>? indIndices;
  DragData({required this.obsIndex, this.indIndices});
}

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
  String _progressMessage = "";
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

  // Individual selection in right pane
  final Set<int> _selectedIndividualIndices = {};
  int? _lastSelectedIndividualIndex;
  // Expanded observation indices

  int _currentCenterPage = 0;
  final PageController _pageController = PageController();

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
    final prefs = await SharedPreferences.getInstance();
    final lastDir = prefs.getString(_kLastPickerDirKey);

    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      initialDirectory: lastDir,
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
      // Remember the directory for next time
      final firstPath = result.files.first.path;
      if (firstPath != null) {
        final dir = File(firstPath).parent.path;
        await prefs.setString(_kLastPickerDirKey, dir);
      }

      // Only process files that haven't already been added
      final pickedPaths = result.files.map((f) => f.path!).toSet();
      final existingPaths = _selectedFiles.toSet();
      final newPaths = pickedPaths.difference(existingPaths).toList();

      if (newPaths.isEmpty) return; // Nothing new to add

      // Sort new files by size so small ones process first
      newPaths.sort(
        (a, b) => File(a).lengthSync().compareTo(File(b).lengthSync()),
      );

      setState(() {
        _isProcessing = true;
        _progress = 0.0;
        _progressMessage = "Preparing files...";
        _selectedFiles.addAll(newPaths);
        _processingFiles.addAll(newPaths);
      });

      // Pre-extract EXIF for new files
      for (String path in newPaths) {
        try {
          final exif = await ExifService.extractExif(path);
          _imageExifData[path] = exif;
        } catch (_) {
          _imageExifData[path] = ExifData();
        }
      }

      // Re-group ALL files (old + new) chronologically into bursts
      List<Map<String, dynamic>> allFileData = _selectedFiles.map((path) {
        return {'path': path, 'exif': _imageExifData[path] ?? ExifData()};
      }).toList();

      allFileData.sort((a, b) {
        final dateA = (a['exif'] as ExifData).dateTime;
        final dateB = (b['exif'] as ExifData).dateTime;
        if (dateA == null && dateB == null) return 0;
        if (dateA == null) return 1;
        if (dateB == null) return -1;
        return dateA.compareTo(dateB);
      });

      List<List<String>> bursts = [];
      List<String> currentBurst = [];
      DateTime? lastTime;
      for (var data in allFileData) {
        final path = data['path'] as String;
        final date = (data['exif'] as ExifData).dateTime;
        if (date == null) {
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

      setState(() {
        _fileBursts = bursts;
        _selectedFiles = bursts.expand((b) => b).toList();
      });

      // Phase 1: Parallel Detection
      final newPathSet = newPaths.toSet();

      int totalBytesPhase1 = 0;
      for (final p in newPaths) {
        totalBytesPhase1 += File(p).lengthSync();
      }
      int processedBytesPhase1 = 0;
      int totalBursts = bursts.length;
      int completedBurstsPhase2 = 0;
      int totalIdentifications = 0;
      int completedIdentifications = 0;

      setState(() {
        _progressMessage = "Detecting & Classifying...";
        _progress = 0.0;
      });

      Map<String, _Phase1Result> phase1Results = {};
      List<Completer<void>> burstCompleters = List.generate(
        bursts.length,
        (_) => Completer<void>(),
      );

      // --- PHASE 1 WORKER ---
      Future<void> phase1Worker = Future(() async {
        for (int i = 0; i < bursts.length; i++) {
          final burstFiles = bursts[i];

          for (final filePath in burstFiles) {
            if (!newPathSet.contains(filePath)) continue;
            try {
              final processedPath =
                  await ImageConverter.convertToJpegIfNeeded(filePath) ??
                  filePath;
              final exifData = await ExifService.extractExif(filePath);
              List<BirdCrop> detectedBirds = await _detector.detectAndCrop(
                processedPath,
              );

              if (detectedBirds.isEmpty) {
                final fallbackBytes = await File(processedPath).readAsBytes();
                final fallbackImg = await compute(
                  img.decodeImage,
                  fallbackBytes,
                );
                phase1Results[filePath] = _Phase1Result(
                  processedPath: processedPath,
                  exifData: exifData,
                  clusters: [],
                  isFallback: true,
                  fallbackImg: fallbackImg,
                );
              } else {
                final clusters = _clusterer.cluster(detectedBirds);
                phase1Results[filePath] = _Phase1Result(
                  processedPath: processedPath,
                  exifData: exifData,
                  clusters: clusters,
                  isFallback: false,
                  fallbackImg: null,
                );
              }
            } catch (e) {
              debugPrint("Error in phase 1 for $filePath: $e");
            } finally {
              processedBytesPhase1 += File(filePath).lengthSync();
              if (mounted) {
                setState(() {
                  double p1 = totalBytesPhase1 > 0
                      ? processedBytesPhase1 / totalBytesPhase1
                      : 1.0;
                  double p2 = totalBursts > 0
                      ? completedBurstsPhase2 / totalBursts
                      : 1.0;
                  _progress = (p1 * 0.5) + (p2 * 0.5);
                });
              }
            }
          }
          burstCompleters[i].complete();
        }
      });

      // --- PHASE 2 WORKER ---
      Future<void> phase2Worker = Future(() async {
        for (int i = 0; i < bursts.length; i++) {
          await burstCompleters[i].future;

          final burstFiles = bursts[i];
          final burstHasNew = burstFiles.any((p) => newPathSet.contains(p));
          if (!burstHasNew) {
            completedBurstsPhase2++;
            continue; // Skip bursts that are fully already processed
          }

          int burstIdentifications = 0;
          for (final filePath in burstFiles) {
            if (!newPathSet.contains(filePath)) continue;
            final res = phase1Results[filePath];
            if (res == null) continue;
            if (res.isFallback) {
              if (res.fallbackImg != null) burstIdentifications++;
            } else {
              burstIdentifications += res.clusters.length;
            }
          }
          totalIdentifications += burstIdentifications;

          if (mounted && totalIdentifications > 0) {
            setState(() {
              _progressMessage =
                  "Classifying... ($completedIdentifications of $totalIdentifications birds)";
            });
          }

          Map<String, BurstGroup> burstGroupsBySpecies = {};

          for (String filePath in burstFiles) {
            final isNew = newPathSet.contains(filePath);
            if (!isNew) continue; // Only process new files within the burst

            final res = phase1Results[filePath];
            if (res == null) {
              if (mounted) {
                setState(() {
                  _processingFiles.remove(filePath);
                });
              }
              continue;
            }

            try {
              if (res.isFallback) {
                if (res.fallbackImg != null) {
                  final speciesList = await _classifier.classifyFile(
                    res.processedPath,
                    latitude: res.exifData.latitude,
                    longitude: res.exifData.longitude,
                    photoDate: res.exifData.dateTime,
                  );
                  final species = speciesList.isNotEmpty
                      ? speciesList.first
                      : "Unknown";
                  final fullImageBox = Rectangle<int>(
                    0,
                    0,
                    res.fallbackImg!.width,
                    res.fallbackImg!.height,
                  );
                  final obs = Observation(
                    imagePath: filePath,
                    displayPath: res.processedPath,
                    fullImageDisplayPath: res.processedPath,
                    speciesName: species,
                    possibleSpecies: speciesList,
                    exifData: res.exifData,
                    count: 1,
                    boundingBoxes: [fullImageBox],
                  );
                  burstGroupsBySpecies
                      .putIfAbsent(species, () => BurstGroup())
                      .addObservation(obs);

                  completedIdentifications++;
                  if (mounted) {
                    setState(() {
                      _progressMessage =
                          "Classifying... ($completedIdentifications of $totalIdentifications birds)";
                    });
                  }
                }
              } else {
                final Map<String, Observation> photoObservations = {};

                for (int ci = 0; ci < res.clusters.length; ci++) {
                  final clusterCrops = res.clusters[ci];
                  final clusterBoxes = clusterCrops.map((c) => c.box).toList();

                  final speciesList = await _classifier.classifyCluster(
                    res.processedPath,
                    boxes: clusterBoxes,
                    latitude: res.exifData.latitude,
                    longitude: res.exifData.longitude,
                    photoDate: res.exifData.dateTime,
                  );

                  final species = speciesList.isNotEmpty
                      ? speciesList.first
                      : 'Unknown';

                  if (photoObservations.containsKey(species)) {
                    photoObservations[species]!.count += clusterCrops.length;
                    photoObservations[species]!.boundingBoxes.addAll(
                      clusterBoxes,
                    );
                    photoObservations[species]!.boxesByImagePath
                        .putIfAbsent(filePath, () => [])
                        .addAll(clusterBoxes);
                  } else {
                    final cropBytes = clusterCrops.first.croppedJpgBytes;
                    final tempDir = await Directory.systemTemp.createTemp();
                    final filename = filePath.split('/').last;
                    final cropPath = '${tempDir.path}/cluster_${ci}_$filename';
                    await File(cropPath).writeAsBytes(cropBytes);

                    photoObservations[species] = Observation(
                      imagePath: filePath,
                      displayPath: cropPath,
                      fullImageDisplayPath: res.processedPath,
                      speciesName: species,
                      possibleSpecies: speciesList,
                      exifData: res.exifData,
                      count: clusterCrops.length,
                      boundingBoxes: clusterBoxes,
                    );
                  }

                  completedIdentifications++;
                  if (mounted) {
                    setState(() {
                      _progressMessage =
                          "Classifying... ($completedIdentifications of $totalIdentifications birds)";
                    });
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

            if (mounted) {
              setState(() {
                _processingFiles.remove(filePath);
              });
            }
          } // end for filePath in burstFiles

          if (mounted) {
            setState(() {
              for (var bg in burstGroupsBySpecies.values) {
                if (bg.observations.isNotEmpty) {
                  _observations.add(bg.toObservation(burstId: "burst_$i"));
                }
              }
            });
          }

          // Isolate Ollama memory state between bursts to prevent context hallucination bleeding
          await _classifier.unloadModel();

          completedBurstsPhase2++;
          if (mounted) {
            setState(() {
              double p1 = totalBytesPhase1 > 0
                  ? processedBytesPhase1 / totalBytesPhase1
                  : 1.0;
              double p2 = totalBursts > 0
                  ? completedBurstsPhase2 / totalBursts
                  : 1.0;
              _progress = (p1 * 0.5) + (p2 * 0.5);
            });
          }
        } // end for burst
      });

      await Future.wait([phase1Worker, phase2Worker]);

      setState(() {
        _isProcessing = false;
        if (_selectedObservation == null && _observations.isNotEmpty) {
          _selectedObservation = _observations.first;
          _selectedIndividualIndices.clear();
          _lastSelectedIndividualIndex = null;
          _currentCenterPage = 0;
          if (_pageController.hasClients) _pageController.jumpToPage(0);
          _currentlyDisplayedImage = _selectedObservation!.imagePath;
        }
      });
    }
  }

  void _clearAll() {
    setState(() {
      _observations.clear();
      _selectedObservation = null;
      _selectedIndividualIndices.clear();
      _lastSelectedIndividualIndex = null;
      _currentCenterPage = 0;
      _currentlyDisplayedImage = null;
      _fileBursts = [];
      _selectedFiles.clear();
      _processingFiles.clear();
      _imageExifData.clear();
      _progress = 0.0;
      _progressMessage = "";
      _isProcessing = false;
    });
    if (_pageController.hasClients) _pageController.jumpToPage(0);
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
      if (_selectedObservation == from) {
        _selectedObservation = into;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
    });
  }

  void _mergeIndividuals(int fromObsIdx, List<int> indIndices, int intoIdx) {
    if (fromObsIdx == intoIdx) return;
    if (indIndices.isEmpty) return;

    setState(() {
      final from = _observations[fromObsIdx];
      final into = _observations[intoIdx];

      into.count += indIndices.length;
      from.count -= indIndices.length;

      // Sort descending to safely remove elements by index without shifting earlier indices
      final sortedIndices = List<int>.from(indIndices)
        ..sort((a, b) => b.compareTo(a));

      for (final src in List.from(from.sourceImages)) {
        final path = src.imagePath;
        final fromBoxes = from.boxesByImagePath[path];
        if (fromBoxes != null && fromBoxes.isNotEmpty) {
          List<Rectangle<int>> sortedBoxes = List.from(fromBoxes);
          sortedBoxes.sort((a, b) => a.left.compareTo(b.left));

          for (final indIdx in sortedIndices) {
            if (indIdx < sortedBoxes.length) {
              final boxToMove = sortedBoxes[indIdx];
              fromBoxes.remove(boxToMove);
              into.boxesByImagePath.putIfAbsent(path, () => []).add(boxToMove);

              from.boundingBoxes.remove(boxToMove);
              into.boundingBoxes.add(boxToMove);
            }
          }
        }

        if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
          into.sourceImages.add(src);
        }
      }

      for (final s in from.possibleSpecies) {
        if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
      }

      if (from.count <= 0) {
        _observations.removeAt(fromObsIdx);
      } else if (_selectedObservation == from) {
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
      }

      if (_selectedObservation == from && from.count <= 0) {
        _selectedObservation = _observations.isNotEmpty
            ? _observations.first
            : null;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
    });
  }

  void _extractIndividuals(
    int fromObsIdx,
    List<int> indIndices,
    int insertAtIdx,
  ) {
    if (indIndices.isEmpty) return;

    setState(() {
      final from = _observations[fromObsIdx];

      Observation newObs = Observation(
        imagePath: from.imagePath,
        displayPath: from.displayPath,
        fullImageDisplayPath: from.fullImageDisplayPath,
        speciesName: from.speciesName,
        possibleSpecies: List.from(from.possibleSpecies),
        exifData: from.exifData,
        count: indIndices.length,
        boundingBoxes: [],
        sourceImages: [],
        boxesByImagePath: {},
        burstId: from.burstId,
      );

      from.count -= indIndices.length;

      // Sort descending safely
      final sortedIndices = List<int>.from(indIndices)
        ..sort((a, b) => b.compareTo(a));

      for (final src in List.from(from.sourceImages)) {
        final path = src.imagePath;
        final fromBoxes = from.boxesByImagePath[path];
        if (fromBoxes != null && fromBoxes.isNotEmpty) {
          List<Rectangle<int>> sortedBoxes = List.from(fromBoxes);
          sortedBoxes.sort((a, b) => a.left.compareTo(b.left));

          for (final indIdx in sortedIndices) {
            if (indIdx < sortedBoxes.length) {
              final boxToMove = sortedBoxes[indIdx];
              fromBoxes.remove(boxToMove);
              newObs.boxesByImagePath
                  .putIfAbsent(path, () => [])
                  .add(boxToMove);

              from.boundingBoxes.remove(boxToMove);
              newObs.boundingBoxes.add(boxToMove);
            }
          }
        }

        if (newObs.boxesByImagePath.containsKey(path) &&
            newObs.boxesByImagePath[path]!.isNotEmpty) {
          newObs.sourceImages.add(src);
        }
      }

      int actualInsertIdx = insertAtIdx;
      if (from.count <= 0) {
        _observations.removeAt(fromObsIdx);
        if (insertAtIdx > fromObsIdx) {
          actualInsertIdx--;
        }
      } else if (_selectedObservation == from) {
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
      }

      _observations.insert(actualInsertIdx, newObs);

      if (_selectedObservation == from && from.count <= 0) {
        _selectedObservation = newObs;
        _selectedIndividualIndices.clear();
        _lastSelectedIndividualIndex = null;
        _currentCenterPage = 0;
        if (_pageController.hasClients) _pageController.jumpToPage(0);
      }
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

          // Total individuals formally detected as bounding boxes in THIS specific photo
          final individualCount = _observations
              .where((o) => o.sourceImages.any((s) => s.imagePath == file))
              .fold<int>(
                0,
                (sum, o) => sum + (o.boxesByImagePath[file]?.length ?? 0),
              );

          return InkWell(
            onTap: () {
              setState(() {
                _currentlyDisplayedImage = file;
                _selectedObservation = _observations
                    .where((o) => o.imagePath == file)
                    .firstOrNull;
                _selectedIndividualIndices.clear();
                _lastSelectedIndividualIndex = null;
                _currentCenterPage = 0;
                if (_pageController.hasClients) _pageController.jumpToPage(0);
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
          if (_selectedFiles.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _isProcessing ? null : _clearAll,
              tooltip: "Clear all photos and results",
            ),
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
                        Text(
                          _progressMessage.isNotEmpty
                              ? _progressMessage
                              : "Processing images...",
                        ),
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


                      Widget observationItem = ObservationCard(
                        obs: obs,
                        index: index,
                        isSelected: isSelected,
                        isDragging: isDragging,
                        selectedIndividualIndices: _selectedIndividualIndices.toList(),
                        lastSelectedIndividualIndex: _lastSelectedIndividualIndex,
                        onTapCard: () {
                          setState(() {
                            _selectedObservation = obs;
                            _currentlyDisplayedImage = obs.imagePath;
                            _selectedIndividualIndices.clear();
                            _lastSelectedIndividualIndex = null;
                            _currentCenterPage = 0;
                            if (_pageController.hasClients) {
                              _pageController.jumpToPage(0);
                            }
                          });
                        },
                        onTapIndividual: (int i) {
                          final isCtrl = HardwareKeyboard.instance.isControlPressed ||
                                         HardwareKeyboard.instance.isMetaPressed;
                          final isShift = HardwareKeyboard.instance.isShiftPressed;

                          setState(() {
                            if (_selectedObservation != obs) {
                              _selectedObservation = obs;
                              _currentlyDisplayedImage = obs.imagePath;
                              _selectedIndividualIndices.clear();
                              _lastSelectedIndividualIndex = null;
                            }

                            if (isCtrl) {
                              if (_selectedIndividualIndices.contains(i)) {
                                _selectedIndividualIndices.remove(i);
                                if (_lastSelectedIndividualIndex == i) {
                                  _lastSelectedIndividualIndex = null;
                                }
                              } else {
                                _selectedIndividualIndices.add(i);
                                _lastSelectedIndividualIndex = i;
                              }
                            } else if (isShift && _lastSelectedIndividualIndex != null) {
                              int start = min(_lastSelectedIndividualIndex!, i);
                              int end = max(_lastSelectedIndividualIndex!, i);
                              _selectedIndividualIndices.clear();
                              for (int j = start; j <= end; j++) {
                                _selectedIndividualIndices.add(j);
                              }
                            } else {
                              _selectedIndividualIndices.clear();
                              _selectedIndividualIndices.add(i);
                              _lastSelectedIndividualIndex = i;
                            }

                            _currentCenterPage = 0;
                            if (_pageController.hasClients) {
                              _pageController.jumpToPage(0);
                            }
                          });
                        },
                        onSpeciesChanged: (String val) {
                          obs.speciesName = val;
                        },
                        onSpeciesSelected: (String choice) {
                          setState(() {
                            obs.speciesName = choice;
                          });
                        },
                        onCountChanged: (int count) {
                          obs.count = count;
                        },
                        onMergeObservations: _mergeObservations,
                        onMergeIndividuals: _mergeIndividuals,
                        onDragStarted: (int dragIndex) {
                          setState(() => _draggingIndex = dragIndex);
                        },
                        onDragEnded: () {
                          setState(() => _draggingIndex = null);
                        },
                      );
                      bool isFirstInBurst = index > 0 &&
                          _observations[index].burstId != _observations[index - 1].burstId;

                      Widget dropZone(int insertIndex) {
                        return DragTarget<DragData>(
                          onWillAcceptWithDetails: (details) {
                            if (details.data.indIndices == null) return false;
                            final srcObs = _observations[details.data.obsIndex];
                            // Must be from the same burst
                            if (srcObs.burstId != _observations[index].burstId) {
                              return false;
                            }
                            return true;
                          },
                          onAcceptWithDetails: (details) {
                            _extractIndividuals(
                              details.data.obsIndex,
                              details.data.indIndices!,
                              insertIndex,
                            );
                          },
                          builder: (context, candidateData, rejectedData) {
                            return Container(
                              height: 12,
                              margin: const EdgeInsets.symmetric(horizontal: 24),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                color: candidateData.isNotEmpty
                                    ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)
                                    : Colors.transparent,
                              ),
                            );
                          },
                        );
                      }

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isFirstInBurst)
                            const Divider(
                              height: 32,
                              thickness: 1,
                              indent: 32,
                              endIndent: 32,
                              color: Colors.white24,
                            ),
                          dropZone(index),
                          observationItem,
                          if (index == _observations.length - 1)
                            dropZone(index + 1),
                        ],
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
    final obs = _selectedObservation;
    List<SourceImage>? sources;

    if (obs != null) {
      if (_selectedIndividualIndices.isNotEmpty) {
        sources = obs.sourceImages.where((src) {
          final boxes = obs.boxesByImagePath[src.imagePath];
          if (boxes == null) return false;
          return _selectedIndividualIndices.any((idx) => boxes.length > idx);
        }).toList();
        if (sources.isEmpty) {
          sources = obs.sourceImages; // Fallback
        }
      } else {
        sources = obs.sourceImages;
      }
    } else if (_currentlyDisplayedImage != null) {
      sources = [
        (
          imagePath: _currentlyDisplayedImage!,
          fullImageDisplayPath: obs?.fullImageDisplayPath,
        ),
      ];
    }

    if (sources == null || sources.isEmpty) {
      return const Expanded(
        flex: 2,
        child: Center(child: Text('Select photos to begin')),
      );
    }

    final isMulti = sources.length > 1;

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
        final allPhotoBoxes = List<Rectangle<int>>.from(
          obs?.boxesByImagePath[rawPath] ??
              (obs?.imagePath == rawPath ? obs!.boundingBoxes : const []),
        );

        // Sort boxes left-to-right to have a deterministic ordering of "individuals" across photos
        allPhotoBoxes.sort((a, b) => a.left.compareTo(b.left));

        List<Rectangle<int>> photoBoxes = allPhotoBoxes;
        if (_selectedIndividualIndices.isNotEmpty && allPhotoBoxes.isNotEmpty) {
          photoBoxes = [];
          for (int idx in _selectedIndividualIndices) {
            if (idx < allPhotoBoxes.length) {
              photoBoxes.add(allPhotoBoxes[idx]);
            }
          }
        }

        return Stack(
          alignment: Alignment.center,
          fit: StackFit.loose,
          children: [
            Image.file(
              File(displayPath),
              width: double.infinity,
              fit: BoxFit.contain,
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
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
      ];

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

    // Multi-source: PageView for horizontal pagination
    return Expanded(
      flex: 2,
      child: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            // If a text field (or similar input) has primary focus, don't intercept arrow keys.
            // This allows the user to navigate text within the TextField.
            final primaryFocus = FocusManager.instance.primaryFocus;
            if (primaryFocus != null && primaryFocus.context != null) {
              // A simple heuristic: if the focused widget is an EditableText (what TextField uses under the hood)
              if (primaryFocus.context!.widget is EditableText) {
                return KeyEventResult.ignored;
              }
            }

            if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              if (_currentCenterPage > 0) {
                _pageController.previousPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
                return KeyEventResult.handled;
              }
            } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              if (_currentCenterPage < sources!.length - 1) {
                _pageController.nextPage(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                );
                return KeyEventResult.handled;
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: Stack(
          children: [
            PageView.builder(
              controller: _pageController,
              itemCount: sources.length,
              onPageChanged: (i) {
                setState(() {
                  _currentCenterPage = i;
                  _currentlyDisplayedImage = sources![i].imagePath;
                });
              },
              itemBuilder: (context, i) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: photoCard(sources![i]),
                );
              },
            ),
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.photo_library,
                      size: 14,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_currentCenterPage + 1} / ${sources.length}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_currentCenterPage > 0)
              Positioned(
                left: 16,
                bottom: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    hoverColor: Colors.black87,
                  ),
                  tooltip: "Previous photo",
                  onPressed: () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
            if (_currentCenterPage < sources.length - 1)
              Positioned(
                right: 16,
                bottom: 16,
                child: IconButton(
                  icon: const Icon(Icons.arrow_forward, color: Colors.white),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black54,
                    hoverColor: Colors.black87,
                  ),
                  tooltip: "Next photo",
                  onPressed: () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    );
                  },
                ),
              ),
          ],
        ),
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

class _Phase1Result {
  final String processedPath;
  final ExifData exifData;
  final List<List<BirdCrop>> clusters;
  final bool isFallback;
  final img.Image? fallbackImg;

  _Phase1Result({
    required this.processedPath,
    required this.exifData,
    required this.clusters,
    required this.isFallback,
    this.fallbackImg,
  });
}
