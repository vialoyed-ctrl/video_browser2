import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';

class _ChallengeRetryAdapter implements HttpClientAdapter {
  _ChallengeRetryAdapter();

  final Completer<void> refreshStarted = Completer<void>();
  final Completer<void> releaseRefresh = Completer<void>();
  int searchRequests = 0;

  static const String _challenge = '''
    <html><a href="https://91.example.test/cdn-cgi/challenge">verify</a>
    <script>window.__cf_chl_test = true</script></html>
  ''';
  static final String _searchPage =
      '<html><h5 class="container-title">cached search page</h5><!--'
      '${List<String>.filled(1200, 'x').join()}--></html>';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/cdn-cgi/challenge') {
      return ResponseBody.fromString('', 200);
    }
    if (options.uri.path == '/search') {
      searchRequests++;
      if (searchRequests == 1) {
        return ResponseBody.fromString(_challenge, 200);
      }
      if (searchRequests == 2) {
        return ResponseBody.fromString(_searchPage, 200);
      }

      if (!refreshStarted.isCompleted) refreshStarted.complete();
      await releaseRefresh.future;
      return ResponseBody.fromString(_searchPage, 200);
    }
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _MarkedSitePageAdapter implements HttpClientAdapter {
  int searchRequests = 0;

  static const String _page = '''
    <html>
      <h5 class="container-title">one result</h5>
      <div class="video-elem">
        <a href="/video/view/marked-video"><img src="/cover.jpg"></a>
        <a class="title" href="/video/view/marked-video">Marked result</a>
      </div>
      <script>window.__cf_chl_management = true</script>
    </html>
  ''';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/search') {
      searchRequests++;
      return ResponseBody.fromString(_page, 200);
    }
    return ResponseBody.fromString('', 200);
  }

  @override
  void close({bool force = false}) {}
}

class _NotFoundAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      '<html><script>window.__cf_chl_generic = true</script><h1>Not Found</h1></html>',
      404,
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a plain 404 search does not trigger slow mirror probes', () async {
    final adapter = _NotFoundAdapter();
    final dio = Dio(
      BaseOptions(validateStatus: (status) => status != null && status < 500),
    )..httpClientAdapter = adapter;
    final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);

    try {
      final page = await source
          .search(query: const SearchQuery(keyword: 'no-such-result'), page: 1)
          .timeout(const Duration(seconds: 1));

      expect(page.items, isEmpty);
      expect(adapter.requests, 1);
    } finally {
      dio.close(force: true);
    }
  });

  test(
    'valid 91 results with a Cloudflare script skip the extra retry',
    () async {
      final adapter = _MarkedSitePageAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);

      try {
        final page = await source.search(
          query: const SearchQuery(keyword: 'marked-test'),
          page: 1,
        );

        expect(page.items, hasLength(1));
        expect(page.items.single.title, 'Marked result');
        expect(adapter.searchRequests, 1);
      } finally {
        dio.close(force: true);
      }
    },
  );

  test(
    'successful challenge retry is cached for an immediate repeat search',
    () async {
      final adapter = _ChallengeRetryAdapter();
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91Source(baseUrl: 'https://91.example.test', dio: dio);
      const query = SearchQuery(keyword: 'cache-test');

      try {
        final first = await source.search(query: query, page: 1);
        expect(first.summary, 'cached search page');
        expect(
          adapter.searchRequests,
          2,
        ); // challenge page, then successful retry

        final stopwatch = Stopwatch()..start();
        final second = await source
            .search(query: query, page: 1)
            .timeout(const Duration(seconds: 1));
        stopwatch.stop();

        expect(second.summary, first.summary);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
        await adapter.refreshStarted.future.timeout(const Duration(seconds: 1));
        expect(
          adapter.searchRequests,
          3,
        ); // only the background refresh hit web

        final third = await source
            .search(query: query, page: 1)
            .timeout(const Duration(seconds: 1));
        expect(third.summary, first.summary);
        expect(
          adapter.searchRequests,
          3,
        ); // another cache read reuses the pending background refresh
      } finally {
        if (!adapter.releaseRefresh.isCompleted) {
          adapter.releaseRefresh.complete();
        }
        dio.close(force: true);
      }
    },
  );
}
