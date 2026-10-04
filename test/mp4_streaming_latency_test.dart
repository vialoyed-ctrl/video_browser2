import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/services/hanime_mp4_range_proxy.dart';

void main() {
  test(
    'first bytes arrive before the origin finishes; replay uses disk',
    () async {
      final proxy = HanimeMp4RangeProxy.instance;
      final cache = await Directory.systemTemp.createTemp(
        'mp4-streaming-test-',
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final client = HttpClient();
      final releaseTail = Completer<void>();
      final bytes = Uint8List.fromList(
        List.generate(HanimeMp4RangeProxy.chunkSize, (index) => index % 251),
      );
      var requests = 0;
      var tailSent = false;
      final subscription = origin.listen((request) async {
        requests++;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          'Content-Range',
          'bytes 0-${bytes.length - 1}/${bytes.length}',
        );
        request.response.contentLength = bytes.length;
        request.response.bufferOutput = false;
        request.response.add(bytes.sublist(0, 16384));
        await request.response.flush();
        await releaseTail.future;
        tailSent = true;
        request.response.add(bytes.sublist(16384));
        await request.response.close();
      });
      try {
        proxy.setPrefetchEnabled(false);
        await proxy.init(cacheDirectory: cache);
        final url = Uri.parse(
          proxy.getProxiedUrl(
            url: 'http://127.0.0.1:${origin.port}/sample.mp4',
            videoId: 'streaming-test',
            referer: 'http://localhost/',
          ),
        );
        Future<HttpClientResponse> fetch() async {
          final request = await client.getUrl(url);
          request.headers.set('Range', 'bytes=0-${bytes.length - 1}');
          return request.close();
        }

        final response = await fetch().timeout(const Duration(seconds: 3));
        final firstByte = Completer<void>();
        final received = BytesBuilder();
        final complete = response.listen((data) {
          received.add(data);
          if (!firstByte.isCompleted) firstByte.complete();
        }).asFuture<void>();
        await firstByte.future.timeout(const Duration(seconds: 3));
        expect(
          tailSent,
          isFalse,
          reason: 'Playback must not wait for the full block',
        );
        releaseTail.complete();
        await complete;
        expect(received.takeBytes(), bytes);

        final replay = await fetch();
        final replayBytes = await replay.fold<List<int>>(
          [],
          (result, data) => result..addAll(data),
        );
        expect(replayBytes, bytes);
        expect(
          requests,
          1,
          reason: 'A cached seek must avoid another origin request',
        );
      } finally {
        if (!releaseTail.isCompleted) releaseTail.complete();
        client.close(force: true);
        await proxy.close();
        await subscription.cancel();
        await origin.close(force: true);
        await cache.delete(recursive: true);
      }
    },
  );
}
