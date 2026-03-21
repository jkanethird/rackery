import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';
import 'package:ebird_generator/services/bird_classifier.dart';
import 'package:ebird_generator/services/bird_clusterer.dart';
import 'package:ebird_generator/services/burst_grouper.dart';
import 'package:ebird_generator/services/csv_service.dart';
import 'package:ebird_generator/services/image_converter.dart';
import 'package:ebird_generator/services/bird_detector.dart';
import 'package:ebird_generator/services/photo_processor.dart';

const _kLastPickerDirKey = 'last_picker_directory';

class ChecklistController extends ChangeNotifier {
  // ─── Services ────────────────────────────────────────────────────────────
  final BirdClassifier _classifier = BirdClassifier();
  final BirdDetector _detector = BirdDetector();
  final BirdClusterer _clusterer = const BirdClusterer();
  final BurstGrouper _burstGrouper = const BurstGrouper();

  // ─── App State ───────────────────────────────────────────────────────────
  bool isInit = false;
  bool isProcessing = false;
  double progress = 0.0;
  String progressMessage = '';

  final List<Observation> observations = [];
  Observation? selectedObservation;
  String? currentlyDisplayedImage;

  // Left panel state
  List<String> selectedFiles = [];
  final Set<String> processingFiles = {};
  final Set<String> activeFiles = {};
  final Map<String, ExifData> imageExifData = {};
  List<List<String>> fileBursts = [];

  // Cache on-demand HEIC→JPEG conversions
  final Map<String, String> _convertedHeicPaths = {};

  // Right panel scroll controller
  final ScrollController observationScrollController = ScrollController();

  // Individual selection
  final Set<int> selectedIndividualIndices = {};
  int? lastSelectedIndividualIndex;
  int? draggingIndex;

  // Center pane pager
  int currentCenterPage = 0;
  final PageController pageController = PageController();

  ChecklistController() {
    _initClassifier();
  }

  Future<void> _initClassifier() async {
    try {
      await _classifier.init();
      await _detector.init();
      isInit = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing classifier: $e');
    }
  }

  @override
  void dispose() {
    _classifier.dispose();
    _detector.dispose();
    observationScrollController.dispose();
    pageController.dispose();
    super.dispose();
  }

  // ─── Display path resolution ─────────────────────────────────────────────

  Future<String?> getDisplayPath(String imagePath) async {
    if (selectedObservation?.imagePath == imagePath) {
      final path = selectedObservation!.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    }
    try {
      final obs = observations.firstWhere((o) => o.imagePath == imagePath);
      final path = obs.fullImageDisplayPath;
      if (path != null && !path.toLowerCase().endsWith('.heic')) return path;
    } catch (_) {}

    if (!imagePath.toLowerCase().endsWith('.heic') &&
        !imagePath.toLowerCase().endsWith('.heif')) {
      return imagePath;
    }

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

  Future<Size> getImageSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    return Size(decoded.width.toDouble(), decoded.height.toDouble());
  }

  // ─── Photo selection & processing ────────────────────────────────────────

  Future<void> selectAndProcessPhotos(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    final lastDir = prefs.getString(_kLastPickerDirKey);

    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      initialDirectory: lastDir,
      allowedExtensions: [
        'jpg', 'jpeg', 'png', 'heic', 'heif',
        'JPG', 'JPEG', 'PNG', 'HEIC', 'HEIF',
      ],
    );

    if (result == null) return;

    final firstPath = result.files.first.path;
    if (firstPath != null) {
      await prefs.setString(_kLastPickerDirKey, File(firstPath).parent.path);
    }

    final pickedPaths = result.files.map((f) => f.path!).toSet();
    final newPaths = pickedPaths.difference(selectedFiles.toSet()).toList();
    if (newPaths.isEmpty) return;

    newPaths.sort((a, b) => File(a).lengthSync().compareTo(File(b).lengthSync()));

    isProcessing = true;
    progress = 0.0;
    progressMessage = 'Preparing files...';
    selectedFiles.addAll(newPaths);
    processingFiles.addAll(newPaths);
    notifyListeners();

    for (final path in newPaths) {
      try {
        imageExifData[path] = await ExifService.extractExif(path);
      } catch (_) {
        imageExifData[path] = ExifData();
      }
    }

    final allFileData = selectedFiles.map((path) {
      return {'path': path, 'exif': imageExifData[path] ?? ExifData()};
    }).toList();

    allFileData.sort((a, b) {
      final dateA = (a['exif'] as ExifData).dateTime;
      final dateB = (b['exif'] as ExifData).dateTime;
      if (dateA == null && dateB == null) return 0;
      if (dateA == null) return 1;
      if (dateB == null) return -1;
      return dateA.compareTo(dateB);
    });

    final bursts = _burstGrouper.group(allFileData);

    fileBursts = bursts;
    selectedFiles = bursts.expand((b) => b).toList();
    notifyListeners();

    final processor = PhotoProcessor(
      classifier: _classifier,
      detector: _detector,
      clusterer: _clusterer,
    );

    await processor.run(
      newPaths: newPaths,
      bursts: bursts,
      onProgress: (value) {
        progress = value;
        notifyListeners();
      },
      onProgressMessage: (msg) {
        progressMessage = msg;
        notifyListeners();
      },
      onObservationAdded: (newObs) {
        observations.addAll(newObs);
        notifyListeners();
      },
      onFileStarted: (filePath) {
        activeFiles.add(filePath);
        notifyListeners();
      },
      onFileCompleted: (filePath) {
        processingFiles.remove(filePath);
        activeFiles.remove(filePath);
        notifyListeners();
      },
      onError: (filePath, error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error processing $filePath: $error')),
          );
        }
      },
    );

    isProcessing = false;
    activeFiles.clear();
    if (selectedObservation == null && observations.isNotEmpty) {
      selectedObservation = observations.first;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
      currentlyDisplayedImage = selectedObservation!.imagePath;
    }
    notifyListeners();
  }

  // ─── Clear ───────────────────────────────────────────────────────────────

  void clearAll() {
    observations.clear();
    selectedObservation = null;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    currentlyDisplayedImage = null;
    fileBursts.clear();
    selectedFiles.clear();
    processingFiles.clear();
    activeFiles.clear();
    imageExifData.clear();
    progress = 0.0;
    progressMessage = '';
    isProcessing = false;
    if (pageController.hasClients) pageController.jumpToPage(0);
    notifyListeners();
  }

  // ─── Export ──────────────────────────────────────────────────────────────

  Future<void> exportCsv(BuildContext context) async {
    String? outputFile = await FilePicker.platform.saveFile(
      dialogTitle: 'Please select an output file:',
      fileName: 'ebird_checklist.csv',
      type: FileType.custom,
      allowedExtensions: ['csv'],
    );
    if (outputFile == null) return;

    if (!outputFile.endsWith('.csv')) outputFile += '.csv';
    await CsvService.generateEbirdCsv(observations, outputFile);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV exported to $outputFile')),
      );
    }
  }

  // ─── Selection Helpers ───────────────────────────────────────────────────

  void selectFile(String file) {
    currentlyDisplayedImage = file;
    selectedObservation = observations
        .where((o) => o.imagePath == file)
        .firstOrNull;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void selectObservation(Observation obs) {
    selectedObservation = obs;
    currentlyDisplayedImage = obs.imagePath;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentCenterPage = 0;
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void selectIndividual(Observation obs, int i) {
    if (selectedObservation != obs) {
      selectedObservation = obs;
      currentlyDisplayedImage = obs.imagePath;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    selectedIndividualIndices.clear();
    selectedIndividualIndices.add(i);
    lastSelectedIndividualIndex = i;
    currentCenterPage = 0;
    if (pageController.hasClients) {
      pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void scrollToObservationForImage(String imagePath) {
    if (!observationScrollController.hasClients) return;
    final idx = observations.indexWhere((o) => o.imagePath == imagePath);
    if (idx < 0) return;
    const estimatedItemHeight = 96.0;
    final target = (idx * estimatedItemHeight).clamp(
      0.0,
      observationScrollController.position.maxScrollExtent,
    );
    observationScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  // ─── Merge / extract operations ──────────────────────────────────────────

  void setDraggingIndex(int? idx) {
    draggingIndex = idx;
    notifyListeners();
  }

  void setCenterPage(int page, String imagePath) {
    currentCenterPage = page;
    currentlyDisplayedImage = imagePath;
    notifyListeners();
  }

  void updateObservationSpecies(Observation obs, String species) {
    obs.speciesName = species;
    notifyListeners();
  }

  void updateObservationCount(Observation obs, int count) {
    obs.count = count;
    notifyListeners();
  }

  void mergeObservations(int fromIdx, int intoIdx) {
    if (fromIdx == intoIdx) return;
    final from = observations[fromIdx];
    final into = observations[intoIdx];
    into.count += from.count;
    into.boundingBoxes.addAll(from.boundingBoxes);
    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    final existingPaths = into.sourceImages.map((s) => s.imagePath).toSet();
    for (final src in from.sourceImages) {
      if (existingPaths.add(src.imagePath)) into.sourceImages.add(src);
    }
    for (final entry in from.boxesByImagePath.entries) {
      into.boxesByImagePath.putIfAbsent(entry.key, () => []).addAll(entry.value);
    }
    observations.removeAt(fromIdx);
    if (selectedObservation == from) {
      selectedObservation = into;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void mergeIndividuals(int fromObsIdx, List<int> indIndices, int intoIdx) {
    if (fromObsIdx == intoIdx || indIndices.isEmpty) return;
    final from = observations[fromObsIdx];
    final into = observations[intoIdx];
    into.count += indIndices.length;
    from.count -= indIndices.length;

    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    for (final src in List.from(from.sourceImages)) {
      final path = src.imagePath;
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null && fromBoxes.isNotEmpty) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final idx in sortedIndices) {
          if (idx < sortedBoxes.length) {
            final box = sortedBoxes[idx];
            fromBoxes.remove(box);
            into.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            into.boundingBoxes.add(box);
          }
        }
      }
      into.boxesByImagePath.putIfAbsent(path, () => []);
      if (!into.sourceImages.any((s) => s.imagePath == src.imagePath)) {
        into.sourceImages.add(src);
      }
    }
    for (final s in from.possibleSpecies) {
      if (!into.possibleSpecies.contains(s)) into.possibleSpecies.add(s);
    }
    if (from.count <= 0) {
      observations.removeAt(fromObsIdx);
    } else if (selectedObservation == from) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    if (selectedObservation == from && from.count <= 0) {
      selectedObservation =
          observations.isNotEmpty ? observations.first : null;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
    }
    notifyListeners();
  }

  void extractIndividuals(
    int fromObsIdx,
    List<int> indIndices,
    int insertAtIdx,
  ) {
    if (indIndices.isEmpty) return;
    
    final from = observations[fromObsIdx];

    final newObs = Observation(
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

    final sortedIndices = List<int>.from(indIndices)
      ..sort((a, b) => b.compareTo(a));

    for (final src in List.from(from.sourceImages)) {
      final path = src.imagePath;
      final fromBoxes = from.boxesByImagePath[path];
      if (fromBoxes != null && fromBoxes.isNotEmpty) {
        final sortedBoxes = List<Rectangle<int>>.from(fromBoxes)
          ..sort((a, b) => a.left.compareTo(b.left));
        for (final idx in sortedIndices) {
          if (idx < sortedBoxes.length) {
            final box = sortedBoxes[idx];
            fromBoxes.remove(box);
            newObs.boxesByImagePath.putIfAbsent(path, () => []).add(box);
            from.boundingBoxes.remove(box);
            newObs.boundingBoxes.add(box);
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
      observations.removeAt(fromObsIdx);
      if (insertAtIdx > fromObsIdx) actualInsertIdx--;
    } else if (selectedObservation == from) {
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
    }
    observations.insert(actualInsertIdx, newObs);
    if (selectedObservation == from && from.count <= 0) {
      selectedObservation = newObs;
      selectedIndividualIndices.clear();
      lastSelectedIndividualIndex = null;
      currentCenterPage = 0;
      if (pageController.hasClients) pageController.jumpToPage(0);
    }
    notifyListeners();
  }
}
