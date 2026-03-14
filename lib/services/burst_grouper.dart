import 'package:ebird_generator/services/exif_service.dart';

/// Groups a sorted list of file-exif pairs into "bursts" — sequences of photos
/// taken within [burstGapSeconds] of each other.
///
/// Photos without timestamps are placed in their own single-file burst.
class BurstGrouper {
  /// Maximum gap in seconds between consecutive photos for them to be
  /// considered part of the same burst.
  final int burstGapSeconds;

  const BurstGrouper({this.burstGapSeconds = 15});

  /// [fileData] is a list of `{'path': String, 'exif': ExifData}` maps,
  /// pre-sorted chronologically by the caller.
  ///
  /// Returns a list of bursts, each burst being the file paths it contains.
  List<List<String>> group(List<Map<String, dynamic>> fileData) {
    final List<List<String>> bursts = [];
    List<String> currentBurst = [];
    DateTime? lastTime;

    for (final data in fileData) {
      final path = data['path'] as String;
      final date = (data['exif'] as ExifData).dateTime;

      if (date == null) {
        // No timestamp: flush current burst and emit a solo burst.
        if (currentBurst.isNotEmpty) bursts.add(List.from(currentBurst));
        bursts.add([path]);
        currentBurst.clear();
        lastTime = null;
      } else if (lastTime == null) {
        currentBurst.add(path);
        lastTime = date;
      } else {
        final diffSeconds = date.difference(lastTime).inSeconds.abs();
        if (diffSeconds <= burstGapSeconds) {
          currentBurst.add(path);
        } else {
          bursts.add(List.from(currentBurst));
          currentBurst = [path];
        }
        lastTime = date;
      }
    }

    if (currentBurst.isNotEmpty) bursts.add(currentBurst);
    return bursts;
  }
}
