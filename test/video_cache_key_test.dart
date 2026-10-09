import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/services/video_cache_key.dart';

void main() {
  test('cache keys are deterministic and safe for long source URLs', () {
    const url =
        'https://cdn.example/videos/episode-01.mp4?token=temporary&quality=1080';
    final first = videoCacheKey(url);

    expect(videoCacheKey(url), first);
    expect(videoCacheKey('$url&variant=2'), isNot(first));
    expect(first, matches(RegExp(r'^[a-zA-Z0-9_-]+$')));
  });

  test('91 cache keys prefer stable view keys over changing host names', () {
    const first = 'https://91porny.com/video/view/abc?viewkey=stable123';
    const mirror = 'https://91tanhua189.sbs/video/view/abc?viewkey=stable123';

    expect(videoCacheKey(first), 'vk_stable123');
    expect(videoCacheKey(mirror), videoCacheKey(first));
  });
}
