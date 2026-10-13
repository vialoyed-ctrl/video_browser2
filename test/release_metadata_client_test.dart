import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/services/release_metadata_client.dart';

class UpdateResponses implements HttpClientAdapter {
  UpdateResponses({
    this.apiStatus = 200,
    this.fallbackStatus = 200,
    this.apiTimeout = false,
  });
  final int apiStatus, fallbackStatus;
  final bool apiTimeout;
  final calls = <String>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    calls.add(options.uri.host);
    final api = options.uri.host == 'api.github.com';
    if (api && apiTimeout) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionTimeout,
      );
    }
    final status = api ? apiStatus : fallbackStatus;
    return ResponseBody.fromString(
      jsonEncode(
        status == 200
            ? {
                'tag_name': 'v2.0.4',
                'body': 'Neutral update notes',
                'assets': [
                  {
                    'name': 'playback-warehouse-arm64.apk',
                    'browser_download_url': 'https://github.com/vialoyed-ctrl/video_browser2/releases/download/v2.0.4/playback-warehouse-arm64.apk',
                  },
                ],
              }
            : {'message': 'API rate limit exceeded'},
      ),
      status,
      headers: {
        Headers.contentTypeHeader: ['text/plain'],
        if (api && status == 403)
          'x-ratelimit-reset': [
            '${DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
          ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('successful API metadata requires no fallback request', () async {
    final transport = UpdateResponses();
    final client = ReleaseMetadataClient(Dio()..httpClientAdapter = transport);
    expect((await client.fetchLatest())['tag_name'], 'v2.0.4');
    expect(transport.calls, ['api.github.com']);
  });
  for (final code in [403, 429]) {
    test(
      'API $code discovers update through public manifest without retry loop',
      () async {
        final transport = UpdateResponses(apiStatus: code);
        final client = ReleaseMetadataClient(
          Dio()..httpClientAdapter = transport,
        );
        final release = await client.fetchLatest();
        expect(release['tag_name'], 'v2.0.4');
        expect(
          (release['assets'] as List).single['name'],
          'playback-warehouse-arm64.apk',
        );
        expect(transport.calls, [
          'api.github.com',
          'raw.githubusercontent.com',
        ]);
        await client.fetchLatest();
        expect(transport.calls, [
          'api.github.com',
          'raw.githubusercontent.com',
          'raw.githubusercontent.com',
        ]);
      },
    );
  }
  test(
    'API connection timeout still finds the public version metadata',
    () async {
      final transport = UpdateResponses(apiTimeout: true);
      final release = await ReleaseMetadataClient(
        Dio()..httpClientAdapter = transport,
      ).fetchLatest();
      expect(release['tag_name'], 'v2.0.4');
      expect(transport.calls, ['api.github.com', 'raw.githubusercontent.com']);
    },
  );
  test(
    'both endpoints unavailable reports failure rather than latest version',
    () async {
      final transport = UpdateResponses(apiStatus: 403, fallbackStatus: 404);
      await expectLater(
        ReleaseMetadataClient(Dio()..httpClientAdapter = transport)
            .fetchLatest(),
        throwsA(isA<DioException>()),
      );
      expect(transport.calls.length, 2);
    },
  );
}
