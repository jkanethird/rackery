// Rackery - Automatic bird identification and eBird checklist generation.
// Copyright (C) 2026 Joseph J. Kane III
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:file_selector/file_selector.dart';
import 'package:rackery/models/observation.dart';
import 'package:rackery/services/burst_grouper.dart';
import 'package:rackery/services/csv_service.dart';
import 'package:rackery/services/image_converter.dart';
import 'package:rackery/services/bird_detector.dart';
import 'package:rackery/services/photo_processor.dart';
import 'package:rackery/services/ebird_api_service.dart';
import 'package:rackery/services/ingestion_pipeline.dart';
import 'package:rackery/services/exif_service.dart';
import 'package:rackery/utils/name_generator.dart';
import 'package:rackery/utils/observation_operations.dart';

part 'selection_actions.dart';
part 'observation_actions.dart';
part 'manual_detection_actions.dart';
part 'photo_processing_actions.dart';
part 'export_actions.dart';

enum BoundingBoxVisibility { focused, all, hidden }

class ChecklistController extends ChangeNotifier {
  // ─── Services ────────────────────────────────────────────────────────────
  final NativePipeline _pipeline = NativePipeline();
  final BurstGrouper _burstGrouper = const BurstGrouper();

  // Caches
  final Map<String, Size> _imageSizeCache = {};

  // ─── App State ───────────────────────────────────────────────────────────
  bool isInit = false;
  bool isProcessing = false;
  double progress = 0.0;
  String progressMessage = '';
  DateTime? batchStartTime;
  Duration? batchElapsedTime;
  int observationVersion = 0;

  String get executionProvider => _pipeline.executionProvider;

  final List<Observation> observations = [];
  Observation? selectedObservation;
  String? currentlyDisplayedImage;

  // Left panel state
  List<String> selectedFiles = [];
  final Set<String> processingFiles = {};
  final Set<String> activeFiles = {};
  final Map<String, ExifData> imageExifData = {};
  final Map<String, String> imageVisualHashes = {};
  final Map<String, Stopwatch> fileStopwatches = {};
  final Map<String, Duration> fileExtraDurations = {};
  final Map<String, Duration> fileElapsedTimes = {};
  final Map<String, String> fileProgressMessages = {};
  List<List<String>> fileBursts = [];

  // Right panel scroll controller
  final ScrollController observationScrollController = ScrollController();
  Observation? expandedObservation;

  // Individual selection
  final Set<int> selectedIndividualIndices = {};
  int? lastSelectedIndividualIndex;
  int? draggingIndex;
  // Dropdown UI state
  bool isDropdownOpen = false;
  BoundingBoxVisibility boxVisibility = BoundingBoxVisibility.focused;

  void toggleBoundingBoxes() {
    switch (boxVisibility) {
      case BoundingBoxVisibility.focused:
        boxVisibility = BoundingBoxVisibility.all;
        break;
      case BoundingBoxVisibility.all:
        boxVisibility = BoundingBoxVisibility.hidden;
        break;
      case BoundingBoxVisibility.hidden:
        boxVisibility = BoundingBoxVisibility.focused;
        break;
    }
    notify();
  }

  void setBoundingBoxVisibility(BoundingBoxVisibility v) {
    if (boxVisibility != v) {
      boxVisibility = v;
      notify();
    }
  }

  void ensureBoundingBoxesVisible() {
    if (boxVisibility != BoundingBoxVisibility.focused) {
      boxVisibility = BoundingBoxVisibility.focused;
      notify();
    }
  }

  // ─── Lifecycle ──────────────────────────────────────────────────────────

  ChecklistController() {
    _initClassifier();
  }

  Future<void> _initClassifier() async {
    try {
      await _pipeline.init();
      isInit = true;
      notifyListeners();
    } catch (e) {
      debugPrint('Error initializing pipeline: $e');
    }
  }

  @override
  void dispose() {
    _pipeline.dispose();
    observationScrollController.dispose();
    super.dispose();
  }

  /// Public wrapper so part-file extensions can trigger listener updates.
  void notify() => notifyListeners();

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

    return ImageConverter.getDisplayPath(imagePath);
  }

  Future<Size> getImageSize(String path) async {
    if (_imageSizeCache.containsKey(path)) return _imageSizeCache[path]!;
    final bytes = await File(path).readAsBytes();
    final decoded = await decodeImageFromList(bytes);
    final size = Size(decoded.width.toDouble(), decoded.height.toDouble());
    _imageSizeCache[path] = size;
    return size;
  }

  // ─── Simple setters ─────────────────────────────────────────────────────

  void setDraggingIndex(int? idx) {
    draggingIndex = idx;
    notifyListeners();
  }

  void setDropdownOpen(bool isOpen) {
    if (isDropdownOpen != isOpen) {
      isDropdownOpen = isOpen;
      notifyListeners();
    }
  }

  // ─── Clear ───────────────────────────────────────────────────────────────

  void clearAll() {
    observations.clear();
    selectedObservation = null;
    selectedIndividualIndices.clear();
    lastSelectedIndividualIndex = null;
    currentlyDisplayedImage = null;
    fileBursts.clear();
    selectedFiles.clear();
    processingFiles.clear();
    activeFiles.clear();
    imageExifData.clear();
    imageVisualHashes.clear();
    _imageSizeCache.clear();
    fileStopwatches.clear();
    fileExtraDurations.clear();
    fileElapsedTimes.clear();
    fileProgressMessages.clear();
    progress = 0.0;
    progressMessage = '';
    isProcessing = false;
    batchStartTime = null;
    batchElapsedTime = null;
    observationVersion = 0;
    notifyListeners();
  }
}
