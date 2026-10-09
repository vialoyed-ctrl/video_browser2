import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/core/app_logger.dart';

void main() {
  setUp(AppLogger.clear);

  test('redacts private credentials from exported diagnostics', () {
    AppLogger.i(
      'Auth',
      'login user@example.com stream https://media.example/video.mp4?secure=secret123&quality=720',
    );
    AppLogger.e(
      'Request',
      'request failed',
      'Authorization: Bearer bearer-secret',
    );

    final exported = AppLogger.exportAll();
    expect(exported, contains('[email]'));
    expect(exported, contains('secure=[redacted]'));
    expect(exported, contains('quality=720'));
    expect(exported, isNot(contains('user@example.com')));
    expect(exported, isNot(contains('secret123')));
    expect(exported, isNot(contains('bearer-secret')));
  });
}
