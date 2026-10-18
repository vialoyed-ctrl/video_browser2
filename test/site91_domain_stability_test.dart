import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/widgets/domain_picker.dart';

final siteHtml =
    '<title>91PORNY</title><div class="video-elem">${'neutral ' * 300}</div>';

class StabilityAdapter implements HttpClientAdapter {
  StabilityAdapter({this.stall = false});
  final bool stall;
  int canceled = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? request,
    Future<void>? cancelFuture,
  ) async {
    if (stall) {
      final done = Completer<ResponseBody>();
      cancelFuture?.then((_) {
        canceled++;
        if (!done.isCompleted) done.complete(ResponseBody.fromString('', 499));
      });
      return done.future;
    }
    final body = switch (options.uri.host) {
      'dizhi968.com' => '<div id="main"></div>',
      'dizhi969.com' => '<div id="main">91tanhua350.sbs</div>',
      'www.91tanhua350.sbs' => siteHtml,
      _ => '',
    };
    return ResponseBody.fromString(body, body.isEmpty ? 404 : 200);
  }

  @override
  void close({bool force = false}) {}
}

class DelayedDiscovery extends Site91Source {
  final result = Completer<DomainDiscoveryResult>();
  CancelToken? receivedCancel;
  final saved = <String>[];
  @override
  Future<DomainDiscoveryResult> discoverWorkingDomain({
    Set<String> exclude = const {},
    void Function(String, int)? onProgress,
    CancelToken? cancelToken,
  }) {
    receivedCancel = cancelToken;
    return result.future;
  }

  @override
  Future<List<String>> loadCustomDomains() async => ['https://manual.example'];
  @override
  Future<void> saveDomainConfiguration(
    String selectedUrl, {
    required Iterable<String> customDomains,
  }) async {
    saved.add(selectedUrl);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.testMode = true;
  });
  tearDown(Get.reset);
  test(
    'an empty publish shell does not hide the next usable publisher',
    () async {
      final adapter = StabilityAdapter();
      final result = await Site91Source(dio: Dio()..httpClientAdapter = adapter)
          .discoverWorkingDomain();
      expect(result.domain, 'https://www.91tanhua350.sbs');
      expect(result.publishHost, 'https://dizhi969.com');
    },
  );
  testWidgets(
    'publish deadline completes and cancels an unresponsive transport',
    (tester) async {
      final adapter = StabilityAdapter(stall: true);
      final future = Site91Source(dio: Dio()..httpClientAdapter = adapter)
          .discoverWorkingDomain();
      DomainDiscoveryResult? result;
      unawaited(future.then((value) => result = value));
      await tester.pump();
      await tester.pump(const Duration(seconds: 26));
      expect(
        result,
        isNotNull,
        reason: 'The budget must finish even when a transport never returns',
      );
      expect(result!.found, false);
      expect(result!.timedOut, true);
      expect(adapter.canceled, greaterThan(0));
    },
  );
  testWidgets(
    'late discovery cannot replace the manually selected radio item',
    (tester) async {
      final source =
          Get.put<VideoSource>(DelayedDiscovery()) as DelayedDiscovery;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDomainPicker(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('manual.example'));
      source.result.complete(
        const DomainDiscoveryResult(domain: 'https://www.91tanhua350.sbs'),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并使用'));
      await tester.pumpAndSettle();
      expect(source.saved, ['https://manual.example']);
    },
  );
  test('a pre-canceled discovery does not start network work', () async {
    final token = CancelToken()..cancel('closed');
    final adapter = StabilityAdapter(stall: true);
    final result = await Site91Source(dio: Dio()..httpClientAdapter = adapter)
        .discoverWorkingDomain(cancelToken: token);
    expect(result.found, false);
    expect(result.testedPublishHosts, 0);
    expect(result.timedOut, false);
  });
  testWidgets(
    'closing the dialog cancels its discovery without adopting late results',
    (tester) async {
      final source =
          Get.put<VideoSource>(DelayedDiscovery()) as DelayedDiscovery;
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDomainPicker(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(source.receivedCancel, isNotNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(source.receivedCancel!.isCancelled, true);
      source.result.complete(
        const DomainDiscoveryResult(domain: 'https://www.91tanhua350.sbs'),
      );
      await tester.pumpAndSettle();
      expect(source.saved, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
