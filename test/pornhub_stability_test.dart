import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/services/background_decode_transformer.dart';

class _CountingAdapter implements HttpClientAdapter {
  _CountingAdapter(this.statusCode);

  final int statusCode;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '<html><body>test</body></html>',
      statusCode,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _RedirectAdapter implements HttpClientAdapter {
  int requests = 0;
  bool? autoRedirectsEnabled;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    autoRedirectsEnabled = options.followRedirects;
    return ResponseBody.fromString(
      '',
      302,
      headers: const <String, List<String>>{
        'location': <String>['https://outside.example/collect'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _HtmlAdapter implements HttpClientAdapter {
  _HtmlAdapter(
    this.html, {
    this.rejectedPlaylists = 0,
    this.remoteMedia = '[]',
  });

  final String html;
  final String remoteMedia;
  int rejectedPlaylists;
  int pageRequests = 0;
  int playlistRequests = 0;
  final pageAgents = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/video/get_media') {
      return ResponseBody.fromString(
        remoteMedia,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.uri.path.endsWith('.mp4')) {
      return ResponseBody.fromBytes([
        0,
        0,
        0,
        24,
        102,
        116,
        121,
        112,
        105,
        115,
        111,
        109,
      ], 206);
    }
    final playlist = options.uri.path.endsWith('.m3u8');
    if (playlist) {
      playlistRequests++;
      if (rejectedPlaylists > 0) {
        rejectedPlaylists--;
        return ResponseBody.fromString('Gone', 410);
      }
    } else {
      pageRequests++;
      pageAgents.add(options.headers['User-Agent'].toString());
    }
    return ResponseBody.fromString(
      playlist ? '#EXTM3U\n#EXT-X-ENDLIST\n' : html,
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

  test('creator pagination uses official next links, not nonempty cards', () async {
    const card = '''<ul><li data-video-vkey="page-fixture">
      <a href="/view_video.php?viewkey=page-fixture" title="Fixture">
      <img data-src="https://example.com/fixture.jpg"></a></li></ul>''';
    for (final next in [false, true]) {
      final html =
          '$card${next ? '<link rel="next" href="/model/fixture/videos?page=2">' : ''}';
      final source = PornHubSource(
        dio: Dio()..httpClientAdapter = _HtmlAdapter(html),
      );
      final result = await source.fetchCreatorVideos('/model/fixture');
      expect(result.items, isNotEmpty);
      expect(result.hasMore, next);
      expect(result.summary, isNull);
    }
  });

  test(
    'creator network failures remain errors instead of empty feeds',
    () async {
      final source = PornHubSource(
        dio: Dio()..httpClientAdapter = _CountingAdapter(503),
      );
      final result = await source.fetchCreatorVideos('/model/fixture');
      expect(result.summary, PornHubSource.requestFailureMessage);
    },
  );

  test('HTTP 200 challenge pages are not confirmed empty lists', () async {
    final source = PornHubSource(
      dio: Dio()
        ..httpClientAdapter = _HtmlAdapter(
          '<html><title>Just a moment</title></html>',
        ),
    );
    final result = await source.fetchCreatorVideos('/model/fixture');
    expect(result.summary, PornHubSource.requestFailureMessage);
  });

  test('refreshes a rejected CDN before returning a playable detail', () async {
    const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/test.m3u8"}
    ]}</script>''';
    final adapter = _HtmlAdapter(html, rejectedPlaylists: 1);
    final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
    final detail = await source.fetchDetail('cdn-refresh');
    expect(detail, isNotNull);
    expect(adapter.pageRequests, 2);
    expect(adapter.playlistRequests, 2);
    expect(adapter.pageAgents, [
      PornHubSource.playbackUserAgent,
      PornHubSource.playbackFallbackUserAgent,
    ]);
    expect(detail!.variants.single.label, '1080p');
    await source.fetchDetail('cdn-refresh');
    expect(adapter.pageRequests, 2);
    expect(adapter.playlistRequests, 2);
  });

  test(
    'does not cache a route after all CDN validation attempts fail',
    () async {
      const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/test.m3u8"}
    ]}</script>''';
      final adapter = _HtmlAdapter(html, rejectedPlaylists: 3);
      final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
      expect(await source.fetchDetail('cdn-rejected'), isNull);
      expect(source.getCachedHlsUrl('cdn-rejected'), isNull);
      expect(adapter.pageRequests, 3);
      expect(await source.fetchDetail('cdn-rejected'), isNotNull);
      expect(adapter.pageRequests, 4);
    },
  );

  test('rejects a foreign detail URL before making an HTTP request', () async {
    final adapter = _CountingAdapter(200);
    final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);

    final detail = await source.fetchDetail('https://outside.example/video/1');

    expect(detail, isNull);
    expect(adapter.requests, 0);
  });

  test('selects 4K MP4 ahead of default 720p and 1080p HLS', () async {
    const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"720","defaultQuality":true,"videoUrl":"https://em-h.phncdn.com/720.m3u8"},
      {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/1080.m3u8"},
      {"format":"mp4","quality":"4K","height":2160,"videoUrl":"https://cdn.phncdn.com/2160.mp4"}
    ]}</script>''';
    final source = PornHubSource(
      dio: Dio()..httpClientAdapter = _HtmlAdapter(html),
    );
    final detail = await source.fetchDetail('4k-direct');
    expect(detail, isNotNull);
    expect(detail!.video.hlsUrl, endsWith('2160.mp4'));
    expect(detail.variants.map((variant) => variant.label), [
      '2160p',
      '1080p',
      '720p',
    ]);
  });

  test(
    'resolves remote quality API and selects the actual 8K stream',
    () async {
      const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/1080.m3u8"},
      {"format":"mp4","quality":[],"height":2160,"remote":true,"videoUrl":"https://cn.pornhub.com/video/get_media?s=fixture"}
    ]}</script>''';
      const media = '''[
      {"quality":"2160p","videoUrl":"https://cdn.phncdn.com/2160.mp4"},
      {"quality":"8K","videoUrl":"https://cdn.phncdn.com/4320.mp4"}
    ]''';
      final source = PornHubSource(
        dio: Dio()
          ..transformer = BackgroundDecodeTransformer()
          ..httpClientAdapter = _HtmlAdapter(html, remoteMedia: media),
      );
      final detail = await source.fetchDetail('8k-remote');
      expect(detail, isNotNull);
      expect(detail!.video.hlsUrl, endsWith('4320.mp4'));
      expect(detail.variants.first.label, '4320p');
      expect(
        detail.variants.any((variant) => variant.url.contains('/get_media')),
        isFalse,
      );
    },
  );

  test(
    'empty remote API does not invent a 4K stream from endpoint metadata',
    () async {
      const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/1080.m3u8"},
      {"format":"mp4","quality":[],"height":2160,"remote":true,"videoUrl":"https://cn.pornhub.com/video/get_media?s=fixture"}
    ]}</script>''';
      final source = PornHubSource(
        dio: Dio()..httpClientAdapter = _HtmlAdapter(html),
      );
      final detail = await source.fetchDetail('no-4k');
      expect(detail!.variants.single.label, '1080p');
    },
  );

  test('portrait height does not inflate the declared quality', () async {
    const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","height":1920,"width":1080,"videoUrl":"https://em-h.phncdn.com/portrait.m3u8"},
      {"format":"mp4","quality":"2160","videoUrl":"https://cdn.phncdn.com/2160.mp4"}
    ]}</script>''';
    final source = PornHubSource(
      dio: Dio()..httpClientAdapter = _HtmlAdapter(html),
    );
    final detail = await source.fetchDetail('portrait');
    expect(detail!.variants.map((variant) => variant.label), [
      '2160p',
      '1080p',
    ]);
  });

  test('rejects an expired embedded CDN signature before probing it', () async {
    const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"1080","videoUrl":"https://km-h.phncdn.com/test.m3u8?hdnea=st=1000000000~exp=1000000001~hmac=fixture"}
    ]}</script>''';
    final adapter = _HtmlAdapter(html);
    final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);
    expect(await source.fetchDetail('expired-embedded-signature'), isNull);
    expect(adapter.playlistRequests, 0);
    expect(source.getCachedHlsUrl('expired-embedded-signature'), isNull);
  });

  test(
    'keeps a transient HTTP failure retryable instead of marking EOF',
    () async {
      final adapter = _CountingAdapter(503);
      final source = PornHubSource(dio: Dio()..httpClientAdapter = adapter);

      final page = await source.fetchPage(page: 2);

      expect(page.items, isEmpty);
      expect(page.hasMore, isTrue);
      expect(page.summary, PornHubSource.requestFailureMessage);
      expect(adapter.requests, 1);
    },
  );

  test('does not forward a session request to an external redirect', () async {
    final adapter = _RedirectAdapter();
    final dio = Dio(
      BaseOptions(validateStatus: (status) => status != null && status < 500),
    )..httpClientAdapter = adapter;
    final source = PornHubSource(dio: dio);

    final page = await source.fetchPage(page: 1);

    expect(page.summary, PornHubSource.requestFailureMessage);
    expect(adapter.requests, 1);
    expect(adapter.autoRedirectsEnabled, isFalse);
  });

  test('keeps alternate CDN and lower-quality playback routes', () async {
    const detailUrl =
        'https://cn.pornhub.com/view_video.php?viewkey=offline-fixture';
    const html = '''
      <html><head><meta property="og:title" content="Offline fixture"></head>
      <script>{"mediaDefinitions":[
        {"format":"hls","quality":"1080","videoUrl":"https://hv-h.phncdn.com/path/1080.m3u8?e=4102444800&h=fixture&f=1"},
        {"format":"hls","quality":"1080","videoUrl":"https://ev-h.phncdn.com/path/1080.m3u8?validto=4102444800&hash=fixture"},
        {"format":"hls","quality":"720","videoUrl":"https://ev-h.phncdn.com/path/720.m3u8?validto=4102444800&hash=fixture"}
      ]}</script></html>
    ''';
    final dio = Dio(
      BaseOptions(validateStatus: (status) => status != null && status < 500),
    )..httpClientAdapter = _HtmlAdapter(html);
    final source = PornHubSource(dio: dio);

    final detail = await source.fetchDetail(detailUrl);

    expect(detail, isNotNull);
    expect(detail!.video.hlsUrl, contains('ev-h.phncdn.com/path/1080.m3u8'));
    expect(detail.variants.map((variant) => variant.label), <String>[
      '1080p',
      '720p',
    ]);
    final fallbacks = source.fallbackVariantsFor(detailUrl);
    expect(fallbacks, hasLength(2));
    expect(fallbacks.first.label, '1080p备用');
    expect(fallbacks.first.url, contains('hv-h.phncdn.com/path/1080.m3u8'));
    expect(fallbacks.last.label, '720p备用');

    // Symmetric cache lookup by pure viewkey
    expect(source.getCachedHlsUrl('offline-fixture'), detail.video.hlsUrl);
    expect(source.fallbackVariantsFor('offline-fixture'), hasLength(2));
  });

  test('sends User-Agent and age verification cookie for requests', () async {
    RequestOptions? capturedOptions;
    final dio = Dio(
      BaseOptions(validateStatus: (status) => status != null && status < 500),
    );
    dio.httpClientAdapter = _CountingAdapterWithCallback((opts) {
      capturedOptions = opts;
    });
    final source = PornHubSource(dio: dio);

    await source.fetchPage(page: 1);

    expect(capturedOptions, isNotNull);
    expect(
      capturedOptions!.headers['User-Agent'],
      PornHubSource.defaultUserAgent,
    );
    expect(capturedOptions!.headers['Cookie'], contains('age_verified=1'));
  });

  test(
    'uses mobile media routes for details and preserves desktop lists',
    () async {
      final requests = <RequestOptions>[];
      final dio = Dio()
        ..httpClientAdapter = _CountingAdapterWithCallback(requests.add);
      final source = PornHubSource(dio: dio);

      await source.fetchDetail('mobile-profile');
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(
          request.headers['User-Agent'],
          anyOf(
            PornHubSource.playbackUserAgent,
            PornHubSource.playbackFallbackUserAgent,
          ),
        );
        expect(request.headers['Cookie'], contains('platform=mobile'));
      }
      requests.clear();
      await source.fetchPage(page: 1);
      expect(
        requests.single.headers['User-Agent'],
        PornHubSource.defaultUserAgent,
      );
      expect(requests.single.headers['Cookie'], contains('platform=pc'));
    },
  );

  test(
    'parses spaced media definitions and mobile recommendation cards',
    () async {
      const html = '''
      <html><head><meta property="og:title" content="Mobile fixture"></head>
      <script>{"mediaDefinitions" : [
        {"format":"hls","quality":"1080","videoUrl":"https://em-h.phncdn.com/path/1080.m3u8?validto=4102444800"}
      ]}</script>
      <ul><li data-video-vkey="related-fixture">
        <a href="/view_video.php?viewkey=related-fixture"><img src="https://example.test/thumb.jpg"></a>
        <div class="duration"><span class="time">12:34</span></div>
        <a class="uploaderLink">Fixture author</a><div class="videoViews">1.2K</div>
        <a class="thumbnailTitle" href="/view_video.php?viewkey=related-fixture">Related title</a>
      </li><li class="advertisement" data-video-vkey="ad-fixture">
        <a href="/view_video.php?viewkey=ad-fixture">Ad</a>
      </li></ul></html>
    ''';
      final source = PornHubSource(
        dio: Dio()..httpClientAdapter = _HtmlAdapter(html),
      );
      final detail = await source
          .fetchDetail('mobile-fixture')
          .timeout(const Duration(seconds: 2));
      expect(detail, isNotNull);
      expect(detail!.video.hlsUrl, contains('em-h.phncdn.com'));
      expect(detail.variants.single.label, '1080p');
      expect(detail.relatedVideos, hasLength(1));
      final related = detail.relatedVideos.single;
      expect(related.title, 'Related title');
      expect(related.author, 'Fixture author');
      expect(related.duration, const Duration(minutes: 12, seconds: 34));
      expect(related.viewsStr, '1.2K');
    },
  );

  test(
    'coalesces concurrent detail requests without hanging completion',
    () async {
      const html = '''<script>{"mediaDefinitions":[
      {"format":"hls","quality":"720","videoUrl":"https://em-h.phncdn.com/test.m3u8"}
    ]}</script>''';
      final adapter = _HtmlAdapter(html);
      var requests = 0;
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.uri.path == '/view_video.php') requests++;
            handler.next(options);
          },
        ),
      );
      final source = PornHubSource(dio: dio);
      final details = await Future.wait([
        source.fetchDetail('concurrent-fixture'),
        source.fetchDetail(
          'https://cn.pornhub.com/view_video.php?viewkey=concurrent-fixture',
        ),
      ]).timeout(const Duration(seconds: 2));
      expect(requests, 1);
      expect(details.first, isNotNull);
      expect(identical(details.first, details.last), isTrue);
    },
  );
}

class _CountingAdapterWithCallback implements HttpClientAdapter {
  _CountingAdapterWithCallback(this.onFetch);

  final void Function(RequestOptions) onFetch;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onFetch(options);
    return ResponseBody.fromString(
      '<html><body>test</body></html>',
      200,
      headers: const <String, List<String>>{
        Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
