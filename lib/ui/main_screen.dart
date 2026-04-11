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

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rackery/controllers/checklist_controller.dart';
import 'package:rackery/ui/sine_wave_progress.dart';
import 'package:rackery/ui/widgets/file_list_panel.dart';
import 'package:rackery/ui/widgets/center_pane.dart';
import 'package:rackery/ui/widgets/observation_list_panel.dart';
import 'package:rackery/ui/widgets/listenable_selector.dart';
import 'package:rackery/services/ebird_api_service.dart';

String _formatDuration(Duration d) {
  final totalSeconds = d.inSeconds;
  if (totalSeconds < 60) return '${totalSeconds}s';
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes}m ${seconds}s';
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final ChecklistController _controller = ChecklistController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableSelector<ChecklistController, bool>(
      listenable: _controller,
      selector: (c) => c.isInit,
      builder: (context, isInit, _) {
        if (!isInit) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return Scaffold(
          appBar: _buildAppBar(),
          body: Column(
            children: [
              _buildToolbar(),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Left: file list
                    Expanded(
                      flex: 1,
                      child: Container(
                        color: Theme.of(context).cardColor,
                        child: _buildFileListPanel(),
                      ),
                    ),
                    const VerticalDivider(width: 1),

                    // Centre: photo viewer
                    _buildCenterPane(),

                    const VerticalDivider(width: 1),

                    // Right: observations list
                    Expanded(flex: 1, child: _buildObsPanel()),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      title: const Text('Rackery'),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings),
          tooltip: 'Settings (eBird API Key)',
          onPressed: () async {
            final currentKey = await EbirdApiService.getApiKey() ?? '';
            final txtController = TextEditingController(text: currentKey);
            if (!mounted) return;

            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Settings'),
                content: TextField(
                  controller: txtController,
                  decoration: const InputDecoration(
                    labelText: 'eBird API Key',
                    hintText: 'Paste your eBird API Token here',
                    helperText: 'Required for geographic & seasonal filtering.',
                  ),
                  obscureText: true,
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () {
                      EbirdApiService.setApiKey(txtController.text.trim());
                      Navigator.pop(context);
                    },
                    child: const Text('Save'),
                  ),
                ],
              ),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.info_outline),
          tooltip: 'About & Licenses',
          onPressed: () {
            showAboutDialog(
              context: context,
              applicationName: 'Rackery',
              applicationVersion: '0.1.0',
              applicationIcon: const Icon(Icons.flutter_dash, size: 48),
              applicationLegalese:
                  'Powered by BioCLIP (ONNX Runtime) and TensorFlow Lite.',
            );
          },
        ),
        ListenableSelector<ChecklistController, Object>(
          listenable: _controller,
          selector: (c) => (c.selectedFiles.isNotEmpty, c.isProcessing),
          builder: (context, state, _) {
            final (hasFiles, isProcessing) = state as (bool, bool);
            if (!hasFiles) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: isProcessing ? null : _controller.clearAll,
              tooltip: 'Clear all photos and results',
            );
          },
        ),
        ListenableSelector<ChecklistController, Object>(
          listenable: _controller,
          selector: (c) => (c.observations.isEmpty, c.isProcessing),
          builder: (context, state, _) {
            final (isEmpty, isProcessing) = state as (bool, bool);
            return IconButton(
              icon: const Icon(Icons.download),
              onPressed:
                  isEmpty || isProcessing ? null : () => _controller.exportCsv(context),
              tooltip: 'Export eBird checklist CSV',
            );
          },
        ),
      ],
    );
  }

  Widget _buildToolbar() {
    return ListenableSelector<ChecklistController, Object>(
      listenable: _controller,
      selector: (c) => (
        c.isProcessing,
        c.progressMessage,
        c.progress,
        c.batchStartTime,
        c.batchElapsedTime,
        c.observations.length,
      ),
      builder: (context, state, _) {
        final (
          isProcessing,
          progressMessage,
          progress,
          batchStartTime,
          batchElapsedTime,
          obsLength
        ) = state as (bool, String, double, DateTime?, Duration?, int);
        
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: isProcessing
                    ? null
                    : () => _controller.selectAndProcessPhotos(context),
                icon: const Icon(Icons.photo_library),
                label: const Text('Select Photos'),
              ),
              const SizedBox(width: 16),
              if (isProcessing)
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              progressMessage.isNotEmpty
                                  ? progressMessage
                                  : 'Processing images...',
                            ),
                          ),
                          if (batchStartTime != null)
                            _ActiveBatchTimerLabel(startTime: batchStartTime),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SineWaveProgressIndicator(value: progress),
                    ],
                  ),
                )
              else
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        obsLength == 0
                            ? 'No photos selected'
                            : '$obsLength observations generated',
                        style: const TextStyle(fontStyle: FontStyle.italic),
                      ),
                      if (batchElapsedTime != null) ...[
                        const SizedBox(width: 8),
                        Text(
                          'in ${_formatDuration(batchElapsedTime)}',
                          style: TextStyle(
                            fontStyle: FontStyle.italic,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFileListPanel() {
    return ListenableSelector<ChecklistController, Object>(
      listenable: _controller,
      selector: (c) => (
        c.fileBursts.length,
        c.selectedFiles.length,
        Object.hashAll(c.processingFiles),
        Object.hashAll(c.activeFiles),
        c.currentlyDisplayedImage,
        c.observations.length,
        Object.hashAll(c.fileStartTimes.keys),
        Object.hashAll(c.fileElapsedTimes.keys),
      ),
      builder: (context, _, child) {
        return FileListPanel(
          fileBursts: _controller.fileBursts,
          selectedFiles: _controller.selectedFiles,
          processingFiles: _controller.processingFiles,
          activeFiles: _controller.activeFiles,
          imageExifData: _controller.imageExifData,
          observations: _controller.observations,
          currentlyDisplayedImage: _controller.currentlyDisplayedImage,
          fileStartTimes: _controller.fileStartTimes,
          fileElapsedTimes: _controller.fileElapsedTimes,
          onFileTapped: _controller.selectFile,
        );
      },
    );
  }

  Widget _buildCenterPane() {
    return ListenableSelector<ChecklistController, Object>(
      listenable: _controller,
      selector: (c) => (
        identityHashCode(c.selectedObservation),
        Object.hashAll(c.selectedIndividualIndices),
        c.currentlyDisplayedImage,
        c.boxVisibility,
        c.observationVersion,
        Object.hashAll(c.processingFiles),
      ),
      builder: (context, _, child) {
        return CenterPane(
          selectedObservation: _controller.selectedObservation,
          selectedIndividualIndices: _controller.selectedIndividualIndices,
          currentlyDisplayedImage: _controller.currentlyDisplayedImage,
          imageExifData: _controller.imageExifData,
          boxVisibility: _controller.boxVisibility,
          allObservations: _controller.observations,
          onSetBoxVisibility: _controller.setBoundingBoxVisibility,
          processingFiles: _controller.processingFiles,
          getDisplayPath: _controller.getDisplayPath,
          getImageSize: _controller.getImageSize,
          onIndividualSelected: _controller.selectIndividual,
          onDrawBoundingBox: _controller.addManualIndividual,
        );
      },
    );
  }

  Widget _buildObsPanel() {
    return ListenableSelector<ChecklistController, Object>(
      listenable: _controller,
      selector: (c) => (
        c.observations.length,
        c.observationVersion,
        identityHashCode(c.selectedObservation),
        identityHashCode(c.expandedObservation),
        Object.hashAll(c.selectedIndividualIndices),
        c.lastSelectedIndividualIndex,
        c.draggingIndex,
        c.isDropdownOpen,
      ),
      builder: (context, _, child) {
        return ObservationListPanel(
          observations: _controller.observations,
          selectedObservation: _controller.selectedObservation,
          selectedIndividualIndices: _controller.selectedIndividualIndices,
          lastSelectedIndividualIndex: _controller.lastSelectedIndividualIndex,
          expandedObservation: _controller.expandedObservation,
          draggingIndex: _controller.draggingIndex,
          isDropdownOpen: _controller.isDropdownOpen,
          scrollController: _controller.observationScrollController,
          onTapCard: _controller.selectObservation,
          onTapIndividual: (obs, i) =>
              _controller.selectIndividual(obs, i, scroll: false),
          onToggleExpanded: _controller.toggleExpanded,
          onSpeciesChanged: _controller.updateObservationSpecies,
          onSpeciesSelected: _controller.updateObservationSpecies,
          onCountChanged: _controller.updateObservationCount,
          onMergeObservations: _controller.mergeObservations,
          onMergeIndividuals: _controller.mergeIndividuals,
          onDragStarted: _controller.setDraggingIndex,
          onDragEnded: () => _controller.setDraggingIndex(null),
          onExtractIndividuals: _controller.extractIndividuals,
          onDropdownToggled: _controller.setDropdownOpen,
          onDeleteIndividuals: _controller.deleteIndividuals,
          onTapPhoto: _controller.selectPhotoImage,
        );
      },
    );
  }
}

class _ActiveBatchTimerLabel extends StatefulWidget {
  final DateTime startTime;
  const _ActiveBatchTimerLabel({required this.startTime});

  @override
  State<_ActiveBatchTimerLabel> createState() => _ActiveBatchTimerLabelState();
}

class _ActiveBatchTimerLabelState extends State<_ActiveBatchTimerLabel> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(
      _formatDuration(DateTime.now().difference(widget.startTime)),
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontFeatures: const [FontFeature.tabularFigures()],
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
