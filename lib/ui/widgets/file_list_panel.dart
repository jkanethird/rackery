import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:ebird_generator/models/observation.dart';
import 'package:ebird_generator/services/exif_service.dart';

/// Left-side panel that displays all selected files grouped into bursts,
/// with timestamps, processing indicators, elapsed timers, and
/// individual-count badges.
class FileListPanel extends StatefulWidget {
  final List<List<String>> fileBursts;
  final List<String> selectedFiles;
  final Set<String> processingFiles;
  final Set<String> activeFiles;
  final Map<String, ExifData> imageExifData;
  final List<Observation> observations;
  final String? currentlyDisplayedImage;
  final Map<String, DateTime> fileStartTimes;
  final Map<String, Duration> fileElapsedTimes;

  /// Called when the user taps a file tile. Provides the file path.
  final void Function(String filePath) onFileTapped;

  const FileListPanel({
    super.key,
    required this.fileBursts,
    required this.selectedFiles,
    required this.processingFiles,
    required this.activeFiles,
    required this.imageExifData,
    required this.observations,
    required this.currentlyDisplayedImage,
    required this.fileStartTimes,
    required this.fileElapsedTimes,
    required this.onFileTapped,
  });

  @override
  State<FileListPanel> createState() => _FileListPanelState();
}

class _FileListPanelState extends State<FileListPanel> {
  Timer? _ticker;

  @override
  void didUpdateWidget(covariant FileListPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// Starts a 1-second ticker while any files are actively being processed,
  /// so the live elapsed-time labels stay up to date.
  void _syncTicker() {
    if (widget.fileStartTimes.isNotEmpty) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  /// Formats a [Duration] as a compact string: "3s", "1m 12s", etc.
  static String _formatDuration(Duration d) {
    final totalSeconds = d.inSeconds;
    if (totalSeconds < 60) return '${totalSeconds}s';
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes}m ${seconds}s';
  }

  @override
  Widget build(BuildContext context) {
    // Fall back to a flat list if bursts haven't been computed yet
    final bursts = widget.fileBursts.isNotEmpty
        ? widget.fileBursts
        : widget.selectedFiles.map((f) => [f]).toList();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: bursts.length,
      itemBuilder: (context, i) {
        final burstIndex = bursts.length - 1 - i;
        final burstFiles = bursts[burstIndex];
        final isBurst = burstFiles.length > 1;

        final firstFile = burstFiles.first;
        final firstExif = widget.imageExifData[firstFile];
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
          final isProcessing = widget.processingFiles.contains(file);
          final isActive = widget.activeFiles.contains(file);
          final filename = file.split(Platform.pathSeparator).last;
          final isSelected = widget.currentlyDisplayedImage == file;

          final individualCount = widget.observations
              .where((o) => o.sourceImages.any((s) => s.imagePath == file))
              .fold<int>(
                0,
                (sum, o) => sum + (o.boxesByImagePath[file]?.length ?? 0),
              );

          // ── Timer label ──────────────────────────────────────────────
          String? timerLabel;
          if (widget.fileStartTimes.containsKey(file)) {
            // Currently processing — show live elapsed time
            final elapsed = DateTime.now().difference(widget.fileStartTimes[file]!);
            timerLabel = _formatDuration(elapsed);
          } else if (widget.fileElapsedTimes.containsKey(file)) {
            // Finished — show final elapsed time
            timerLabel = _formatDuration(widget.fileElapsedTimes[file]!);
          }

          Widget statusIndicator;
          if (isActive) {
            // Actively being detected/classified right now — full spinner
            statusIndicator = const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            );
          } else if (isProcessing) {
            // In the queue, waiting for its turn — dim spinner
            statusIndicator = Opacity(
              opacity: 0.30,
              child: const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            );
          } else {
            // Done — green check
            statusIndicator = const Icon(
              Icons.check_circle,
              color: Colors.green,
              size: 12,
            );
          }

          return InkWell(
            onTap: () => widget.onFileTapped(file),
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
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (timerLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        timerLabel,
                        style: TextStyle(
                          fontSize: 10,
                          color: isActive
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).hintColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  if (!isProcessing && individualCount > 0)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.15),
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
                  statusIndicator,
                ],
              ),
            ),
          );
        }

        if (!isBurst) {
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

        // Multi-photo burst header
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
}
