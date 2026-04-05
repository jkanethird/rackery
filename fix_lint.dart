// ignore_for_file: avoid_print
import 'dart:io';

void main() {
  final files = [
    '/home/jkane/repos/rackery/test/test_exif.dart',
    '/home/jkane/repos/rackery/test/test_detector_pure.dart',
    '/home/jkane/repos/rackery/test/test_detector_raw.dart',
    '/home/jkane/repos/rackery/test/test_detector2.dart',
    '/home/jkane/repos/rackery/test/test_geo.dart',
    '/home/jkane/repos/rackery/test/test_detector.dart',
    '/home/jkane/repos/rackery/test/test_detector_heic.dart',
    '/home/jkane/repos/rackery/bin/test_turnstone.dart',
  ];

  final ignoreLine =
      '// ignore_for_file: avoid_print, unused_local_variable, await_only_futures, unused_element, unused_import';

  for (var path in files) {
    var file = File(path);
    if (!file.existsSync()) {
      print('Missing: $path');
      continue;
    }
    var content = file.readAsStringSync();
    if (!content.startsWith('// ignore_for_file')) {
      file.writeAsStringSync('$ignoreLine\n$content');
      print('Fixed $path');
    }
  }
}
