import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/services/hanime_mp4_range_proxy.dart';
import 'package:video_browser/app/services/video_cache_key.dart';

void main() {
  group('HanimeMp4RangeProxy byte ranges', () {
    test('parses bounded and open-ended byte ranges', () {
      final bounded = HanimeMp4RangeProxy.parseByteRange('bytes=512-1023');
      expect(bounded?.start, 512);
      expect(bounded?.end, 1023);

      final openEnded = HanimeMp4RangeProxy.parseByteRange('bytes=1048576-');
      expect(openEnded?.start, 1048576);
      expect(openEnded?.end, isNull);
    });

    test('resolves suffix ranges when the file length is known', () {
      final suffix = HanimeMp4RangeProxy.parseByteRange(
        'bytes=-128',
        totalLength: 1000,
      );
      expect(suffix?.start, 872);
      expect(suffix?.end, 999);
    });

    test('rejects malformed, reversed, and out-of-file ranges', () {
      expect(HanimeMp4RangeProxy.parseByteRange('bytes=abc-4'), isNull);
      expect(HanimeMp4RangeProxy.parseByteRange('bytes=10-9'), isNull);
      expect(
        HanimeMp4RangeProxy.parseByteRange('bytes=1000-', totalLength: 1000),
        isNull,
      );
    });
  });

  test('recognizes direct MP4 URLs with query parameters', () {
    expect(
      HanimeMp4RangeProxy.isMp4Url(
        'https://vdownload.example/123-1080p.mp4?token=abc',
      ),
      isTrue,
    );
    expect(
      HanimeMp4RangeProxy.isMp4Url('https://cdn.example/live.m3u8'),
      isFalse,
    );
  });

  test(
    'serves seek ranges from cached MP4 bytes and deduplicates requests',
    () async {
      final proxy = HanimeMp4RangeProxy.instance;
      final cacheDirectory = await Directory.systemTemp.createTemp(
        'hanime-mp4-range-test-',
      );
      final bytes = Uint8List.fromList(
        List<int>.generate(
          3 * HanimeMp4RangeProxy.chunkSize + 12,
          (i) => i % 251,
        ),
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = Dio();
      var upstreamRangeRequests = 0;
      final originSubscription = origin.listen((request) {
        unawaited(() async {
          final range = request.headers.value(HttpHeaders.rangeHeader);
          final match = RegExp(r'^bytes=(\d+)-(\d+)$').firstMatch(range ?? '');
          if (match == null) {
            request.response.statusCode = HttpStatus.badRequest;
            await request.response.close();
            return;
          }
          upstreamRangeRequests++;
          final start = int.parse(match.group(1)!);
          final end = math.min(int.parse(match.group(2)!), bytes.length - 1);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set(
            HttpHeaders.contentRangeHeader,
            'bytes $start-$end/${bytes.length}',
          );
          request.response.headers.contentLength = end - start + 1;
          request.response.add(bytes.sublist(start, end + 1));
          await request.response.close();
        }());
      });

      try {
        proxy.setPrefetchEnabled(false);
        await proxy.init(cacheDirectory: cacheDirectory);
        final upstreamUrl = 'http://127.0.0.1:${origin.port}/sample.mp4';
        final localUrl = proxy.getProxiedUrl(
          url: upstreamUrl,
          videoId: 'range-test',
          referer: 'https://hanime1.me/watch?v=range-test',
        );
        final start = HanimeMp4RangeProxy.chunkSize + 17;
        final end = start + 31;

        Future<Response<List<int>>> fetch(int from, int to) => client.get(
          localUrl,
          options: Options(
            responseType: ResponseType.bytes,
            headers: <String, String>{'Range': 'bytes=$from-$to'},
          ),
        );

        final responses = await Future.wait(<Future<Response<List<int>>>>[
          fetch(start, end),
          fetch(start + 4, end + 4),
        ]);

        expect(upstreamRangeRequests, 1);
        expect(responses[0].statusCode, HttpStatus.partialContent);
        expect(
          responses[0].headers.value(HttpHeaders.contentRangeHeader),
          'bytes $start-$end/${bytes.length}',
        );
        expect(responses[0].data, bytes.sublist(start, end + 1));
        expect(responses[1].data, bytes.sublist(start + 4, end + 5));
      } finally {
        client.close(force: true);
        await proxy.close();
        await originSubscription.cancel();
        await origin.close(force: true);
        if (await cacheDirectory.exists()) {
          await cacheDirectory.delete(recursive: true);
        }
      }
    },
  );

  test('fills a small MP4 into the bounded cache in the background', () async {
    final proxy = HanimeMp4RangeProxy.instance;
    final cacheDirectory = await Directory.systemTemp.createTemp(
      'hanime-mp4-full-cache-test-',
    );
    final bytes = Uint8List.fromList(
      List<int>.generate(
        3 * HanimeMp4RangeProxy.chunkSize + 12,
        (index) => index % 251,
      ),
    );
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final client = Dio();
    var upstreamRangeRequests = 0;
    final originSubscription = origin.listen((request) {
      unawaited(() async {
        final match = RegExp(r'^bytes=(\d+)-(\d+)$')
            .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
        if (match == null) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        upstreamRangeRequests++;
        final start = int.parse(match.group(1)!);
        final end = math.min(int.parse(match.group(2)!), bytes.length - 1);
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-$end/${bytes.length}',
        );
        request.response.contentLength = end - start + 1;
        request.response.add(bytes.sublist(start, end + 1));
        await request.response.close();
      }());
    });

    try {
      proxy.setPrefetchEnabled(true);
      await proxy.init(cacheDirectory: cacheDirectory);
      final upstreamUrl = 'http://127.0.0.1:${origin.port}/small.mp4';
      final localUrl = proxy.getProxiedUrl(
        url: upstreamUrl,
        videoId: 'full-cache-test',
        referer: 'https://hanime1.me/watch?v=full-cache-test',
      );
      final chunkDirectory = Directory(
        '${cacheDirectory.path}/${videoCacheKey('full-cache-test\n$upstreamUrl')}',
      );
      await proxy.prefetchInitial(
        videoId: 'full-cache-test',
        url: upstreamUrl,
        referer: 'https://hanime1.me/watch?v=full-cache-test',
      );

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      var cachedChunkCount = 0;
      while (cachedChunkCount < 4 && DateTime.now().isBefore(deadline)) {
        if (await chunkDirectory.exists()) {
          cachedChunkCount = await chunkDirectory
              .list()
              .where((entry) => entry is File && entry.path.endsWith('.bin'))
              .length;
        }
        if (cachedChunkCount >= 4) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(upstreamRangeRequests, 4);
      expect(cachedChunkCount, 4);

      final seekStart = 3 * HanimeMp4RangeProxy.chunkSize;
      final response = await client.get<List<int>>(
        localUrl,
        options: Options(
          responseType: ResponseType.bytes,
          headers: <String, String>{
            HttpHeaders.rangeHeader: 'bytes=$seekStart-',
          },
        ),
      );
      expect(response.statusCode, HttpStatus.partialContent);
      expect(response.data, bytes.sublist(seekStart));
      expect(
        upstreamRangeRequests,
        4,
        reason: 'A seek into a fully cached small video must stay local',
      );
    } finally {
      client.close(force: true);
      await proxy.close();
      proxy.setPrefetchEnabled(false);
      await originSubscription.cancel();
      await origin.close(force: true);
      if (await cacheDirectory.exists()) {
        await cacheDirectory.delete(recursive: true);
      }
    }
  });
}
