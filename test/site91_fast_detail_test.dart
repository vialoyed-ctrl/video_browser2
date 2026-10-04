import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';

class _HtmlAdapter implements HttpClientAdapter {
  _HtmlAdapter(this.html);

  final String html;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      html,
      200,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RotatingStreamAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '<html><video data-src="https://cdn.example/stream.m3u8?token=$requests"></video></html>',
      200,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _ExpiringStreamAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    final expiresAt =
        DateTime.now().millisecondsSinceEpoch ~/ 1000 +
        (requests == 1 ? -30 : 60);
    return ResponseBody.fromString(
      '<html><video data-src="https://cdn.example/stream.m3u8?token=$requests&t=$expiresAt"></video></html>',
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

  test('returns a 91 stream URL before enriching page metadata', () async {
    const html = '''
      <!doctype html>
      <html><head><title>Full page title</title></head>
      <body>
        <video id="video-play" data-src="https://cdn.example/stream/index.m3u8?token=abc"></video>
        <h1>Full page title</h1>
        <a href="/author/test-user">test-user</a>
        <div class="video-elem">
          <a class="title" href="/video/view/related-1">Related recommendation</a>
        </div>
      </body></html>
    ''';
    final adapter = _HtmlAdapter(html);
    final dio = Dio()..httpClientAdapter = adapter;
    final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);

    try {
      final quick = await source.fetchDetail('/video/view/fast-test');
      expect(quick, isNotNull);
      expect(
        quick!.video.hlsUrl,
        'https://cdn.example/stream/index.m3u8?token=abc',
      );
      expect(quick.video.title, isEmpty);

      final enriched = await source.waitForDetailEnrichment(
        '/video/view/fast-test',
      );
      expect(enriched?.video.title, 'Full page title');
      expect(enriched?.video.author, 'test-user');
      expect(enriched?.relatedVideos, hasLength(1));
      expect(enriched?.relatedVideos.single.title, 'Related recommendation');
      expect(adapter.requests, 1);
    } finally {
      dio.close(force: true);
    }
  });

  test(
    'forceRefresh bypasses cached detail HTML and gets a fresh stream URL',
    () async {
      final adapter = _RotatingStreamAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);

      try {
        final first = await source.fetchDetail('/video/view/refresh-test');
        expect(first?.video.hlsUrl, 'https://cdn.example/stream.m3u8?token=1');
        expect(
          source.getCachedHlsUrl('/video/view/refresh-test'),
          'https://cdn.example/stream.m3u8?token=1',
        );
        await source.waitForDetailEnrichment('/video/view/refresh-test');

        final refreshed = await source.fetchDetail(
          '/video/view/refresh-test',
          forceRefresh: true,
        );

        expect(
          refreshed?.video.hlsUrl,
          'https://cdn.example/stream.m3u8?token=2',
        );
        expect(
          source.getCachedHlsUrl('/video/view/refresh-test'),
          'https://cdn.example/stream.m3u8?token=2',
        );
        expect(adapter.requests, 2);
      } finally {
        dio.close(force: true);
      }
    },
  );

  test(
    'expired 91 stream token immediately refreshes the detail page',
    () async {
      final adapter = _ExpiringStreamAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);

      try {
        final first = await source.fetchDetail('/video/view/expired-test');
        expect(first?.video.hlsUrl, contains('token=1'));
        expect(source.getCachedHlsUrl('/video/view/expired-test'), isNull);
        await source.waitForDetailEnrichment('/video/view/expired-test');

        final refreshed = await source.fetchDetail('/video/view/expired-test');

        expect(refreshed?.video.hlsUrl, contains('token=2'));
        expect(
          source.getCachedHlsUrl('/video/view/expired-test'),
          contains('token=2'),
        );
        expect(adapter.requests, 2);
      } finally {
        dio.close(force: true);
      }
    },
  );
}
