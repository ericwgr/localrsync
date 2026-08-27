import 'package:flutter_test/flutter_test.dart';
import 'package:localsend_isolates/src/isolate/child/upload_isolate.dart';

void main() {
  group('formatUploadFailures', () {
    test('lists every failed file with its exact error', () {
      final message = formatUploadFailures([
        ('docs/plan.txt', '[422] sha256 mismatch'),
        ('docs/notes.txt', 'error sending request: connection reset'),
      ]);

      expect(message, contains('2 file(s) failed to upload:'));
      expect(message, contains('docs/plan.txt — [422] sha256 mismatch'));
      expect(message, contains('docs/notes.txt — error sending request: connection reset'));
    });

    test('abbreviates beyond five files', () {
      final message = formatUploadFailures([for (var i = 0; i < 7; i++) ('f$i.txt', 'err$i')]);

      expect(message, contains('7 file(s) failed to upload:'));
      for (var i = 0; i < 5; i++) {
        expect(message, contains('f$i.txt — err$i'));
      }
      expect(message, contains('… and 2 more'));
      expect(message, isNot(contains('f5.txt')));
    });
  });
}
