import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/services/hls_cache_proxy.dart';

void main() {
  group('HlsCacheProxy byte ranges', () {
    test('parses bounded, open-ended, and suffix ranges', () {
      expect(HlsCacheProxy.parseByteRange('bytes=10-19', 100), (
        start: 10,
        end: 19,
      ));
      expect(HlsCacheProxy.parseByteRange('bytes=90-', 100), (
        start: 90,
        end: 99,
      ));
      expect(HlsCacheProxy.parseByteRange('bytes=-10', 100), (
        start: 90,
        end: 99,
      ));
    });

    test('clamps an end beyond the file length', () {
      expect(HlsCacheProxy.parseByteRange('bytes=90-500', 100), (
        start: 90,
        end: 99,
      ));
    });

    test('rejects malformed, reversed, and unsatisfiable ranges', () {
      expect(HlsCacheProxy.parseByteRange('bytes=abc-4', 100), isNull);
      expect(HlsCacheProxy.parseByteRange('bytes=10-9', 100), isNull);
      expect(HlsCacheProxy.parseByteRange('bytes=100-', 100), isNull);
      expect(HlsCacheProxy.parseByteRange('bytes=-0', 100), isNull);
      expect(HlsCacheProxy.parseByteRange('bytes=0-1,4-5', 100), isNull);
      expect(HlsCacheProxy.parseByteRange('bytes=0-', 0), isNull);
    });
  });
}
