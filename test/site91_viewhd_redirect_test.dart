import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';

class _ViewHdCardAdapter implements HttpClientAdapter {
  final requestedUrls = <Uri>[];

  static const String _html = '''
    <html><body>
      <div class="video-elem">
        <a class="title" href="/video/viewhd/home-video">Homepage video</a>
        <img src="/cover.jpg">
      </div>
      <video id="video-play" data-src="https://cdn.example/stream.m3u8"></video>
    </body></html>
  ''';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestedUrls.add(options.uri);
    return ResponseBody.fromString(
      _html,
      200,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('normalizes viewhd routes on the primary domain and mirror', () {
    final primary = Site91Source(baseUrl: 'https://91porny.com');
    final mirror = Site91Source(baseUrl: 'https://www.91tanhua189.sbs');

    expect(
      primary.rebaseUrl(
        'https://91porny.com/video/viewhd/video-1?from=home#player',
      ),
      'https://91porny.com/video/view/video-1?from=home#player',
    );
    expect(
      mirror.rebaseUrl(
        'https://www.91tanhua189.sbs/video/viewhd/video-2?from=home',
      ),
      'https://www.91tanhua189.sbs/video/view/video-2?from=home',
    );
    expect(
      mirror.rebaseUrl('https://www.91tanhua189.sbs/video/view/video-3'),
      'https://www.91tanhua189.sbs/video/view/video-3',
    );
  });

  test(
    'homepage cards and player requests use the playable view route',
    () async {
      final adapter = _ViewHdCardAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91Source(
        baseUrl: 'https://www.91tanhua189.sbs',
        dio: dio,
      );

      try {
        final page = await source.fetchPage(page: 1);
        expect(page.items, hasLength(1));
        expect(
          page.items.single.detailUrl,
          'https://www.91tanhua189.sbs/video/view/home-video',
        );

        await source.fetchDetail(
          'https://www.91tanhua189.sbs/video/viewhd/player-video?from=home',
        );
        expect(adapter.requestedUrls.last.path, '/video/view/player-video');
        expect(adapter.requestedUrls.last.query, 'from=home');
      } finally {
        dio.close(force: true);
      }
    },
  );
}
