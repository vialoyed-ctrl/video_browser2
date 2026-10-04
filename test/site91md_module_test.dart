import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart' hide SearchController;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/modules/search/search_binding.dart';
import 'package:video_browser/app/modules/search/search_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91md_source.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/home/home_controller.dart';
import 'package:video_browser/app/modules/home/site91md_category_bar.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/user_service.dart';

class _Pages implements HttpClientAdapter {
  final Map<String, String> pages = {};
  final List<String> requested = [];
  final List<Uri> urls = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancel,
  ) async {
    requested.add(options.uri.path);
    urls.add(options.uri);
    return ResponseBody.fromString(
      pages[Uri.decodeComponent(options.uri.path)] ?? '<html></html>',
      200,
    );
  }

  @override
  void close({bool force = false}) {}
}

const nav =
    '<div class="detail_left"><a href="/index.php/vod/type/id/25.html">91视频</a><a href="/index.php/vod/type/id/1.html">麻豆视频</a><a href="/index.php/vod/type/id/25.html">重复</a></div>';
String card(int id) =>
    '<li><p class="img"><img src="/cover$id.jpg" alt="Sample $id"><a href="/index.php/vod/play/id/$id/sid/1/nid/1.html"></a></p><p>Sample $id</p><p><i>10-05</i><strong>638观看</strong></p></li>';
String cards(List<int> ids, {int next = 0}) =>
    '<div class="detail_right_div"><ul>${ids.map(card).join()}</ul>${next > 0 ? '<ul class="nextPage"><a href="/index.php/vod/type/id/25/page/$next.html">下一页</a></ul>' : ''}</div>';

class _ControllerSource extends Site91MdSource {
  _ControllerSource() : super(baseUrl: 'https://md.example.test');
  int attempts = 0;
  @override
  Future<void> fetchCategories({bool refresh = false}) async {}
  @override
  Future<List<String>> fetchHotKeywords() async => [];
  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) async {
    if (page == 2 && attempts++ == 0) throw StateError('temporary failure');
    return VideoPage(
      items: (page == 1 ? ['a', 'b'] : ['b', 'c'])
          .map((id) => VideoItem(id: id, title: id, author: '91麻豆', hlsUrl: ''))
          .toList(),
      page: page,
      hasMore: page == 1,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'site91md_selected_domain': 'https://md.example.test',
    });
    PreloadService.instance.preloadCount.value = 0;
  });
  test('homepage blocks preserve order and deduplicate; detail recommendations', () async {
    final adapter = _Pages();
    adapter.pages['/'] = '${cards([1, 2])}${cards([2, 3])}';
    adapter.pages['/index.php/vod/play/id/1/sid/1/nid/1.html'] =
        '<script>var player_aaaa={"encrypt":0,"url":"https://cdn.example.test/index.m3u8","vod_data":{"vod_name":"Sample"}};</script><div class="sugetVideo"><ul>${card(2)}${card(3)}</ul></div>';
    final source = Site91MdSource(
      baseUrl: 'https://md.example.test',
      dio: Dio()..httpClientAdapter = adapter,
    );
    final home = await source.fetchPage(page: 1);
    expect(home.items.map((v) => v.title), [
      'Sample 1',
      'Sample 2',
      'Sample 3',
    ]);
    final detail = await source.fetchDetail(
      '/index.php/vod/play/id/1/sid/1/nid/1.html',
    );
    expect(detail!.relatedVideos.map((v) => v.title), ['Sample 2', 'Sample 3']);
  });
  test('website search uses encoded keyword and path pagination', () async {
    final adapter = _Pages();
    adapter.pages['/index.php/vod/search/page/1/wd/传媒.html'] =
        '${cards([1])}<div class="nextPage"><a href="/index.php/vod/search/page/2/wd/test.html">2</a></div>';
    final source = Site91MdSource(
      baseUrl: 'https://md.example.test',
      dio: Dio()..httpClientAdapter = adapter,
    );
    final page = await source.search(
      query: const SearchQuery(keyword: '传媒'),
      page: 1,
    );
    expect(
      Uri.decodeComponent(adapter.urls.last.path),
      contains('/page/1/wd/传媒.html'),
    );
    expect(page.hasMore, isTrue);
  });
  test(
    'search route replaces stale controller after changing platform',
    () async {
      final previous = SearchController(_ControllerSource());
      Get.put<SearchController>(previous);
      final selected = _ControllerSource();
      SourceRegistry.register(selected);

      SourceRegistry.setActiveSource(selected);
      SearchBinding().dependencies();
      final current = Get.find<SearchController>();
      expect(identical(previous, current), isFalse);
      expect(current.isSite91Md, isTrue);
      Get.reset();
    },
  );
  test('website sidebar order, current cards and last-page boundary', () async {
    final adapter = _Pages();
    adapter.pages['/'] = '$nav${cards([1, 2])}';
    adapter.pages['/index.php/vod/type/id/25.html'] = cards([1, 2], next: 2);
    adapter.pages['/index.php/vod/type/id/25/page/2.html'] = cards([2, 3]);
    final dio = Dio()..httpClientAdapter = adapter;
    final source = Site91MdSource(baseUrl: 'https://md.example.test', dio: dio);
    await source.fetchCategories();
    expect(source.categoriesForChannel(ChannelType.video).map((c) => c.id), [
      '25',
      '1',
    ]);
    final first = await source.fetchChannelPage(
      channel: ChannelType.video,
      categoryPath: '/index.php/vod/type/id/25.html',
      page: 1,
    );
    expect(first.items.map((v) => v.title), ['Sample 1', 'Sample 2']);
    expect(
      first.items.first.thumbnailUrl,
      'https://md.example.test/cover1.jpg',
    );
    expect(first.items.first.publishedAt, '10-05');
    expect(first.items.first.viewsStr, '638观看');
    expect(first.hasMore, isTrue);
    final last = await source.fetchChannelPage(
      channel: ChannelType.video,
      categoryPath: '/index.php/vod/type/id/25.html',
      page: 2,
    );
    expect(last.items, hasLength(2));
    expect(last.hasMore, isFalse);
    expect(adapter.requested.last, '/index.php/vod/type/id/25/page/2.html');
    await source.flushCacheNow();
    dio.close(force: true);
  });
  test(
    'first use restores the selected domain before building request URLs',
    () async {
      final adapter = _Pages()..pages['/'] = '$nav${cards([1])}';
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91MdSource(dio: dio);
      final page = await source.fetchPage(page: 1);
      await source.fetchCategories();
      expect(page.items, hasLength(1));
      expect(
        adapter.urls.every((uri) => uri.host == 'md.example.test'),
        isTrue,
      );
      await source.flushCacheNow();
      dio.close(force: true);
    },
  );
  test('failed sidebar extraction can be retried', () async {
    final adapter = _Pages();
    final dio = Dio()..httpClientAdapter = adapter;
    final source = Site91MdSource(baseUrl: 'https://md.example.test', dio: dio);
    await expectLater(source.fetchCategories(), throwsStateError);
    adapter.pages['/'] = nav;
    await source.fetchCategories(refresh: true);
    expect(source.categoriesForChannel(ChannelType.video), hasLength(2));
    await source.flushCacheNow();
    dio.close(force: true);
  });
  for (final encrypt in [0, 1, 2]) {
    test('player metadata and stream decode encrypt=$encrypt', () async {
      const url = 'https://cdn.example.test/video.m3u8?token=abc&quality=720';
      final encoded = encrypt == 0
          ? url
          : encrypt == 1
          ? Uri.encodeComponent(url)
          : base64Encode(utf8.encode(Uri.encodeComponent(url)));
      final adapter = _Pages();
      adapter.pages['/index.php/vod/play/id/1/sid/1/nid/1.html'] =
          '<script>var player_aaaa=${jsonEncode({
            'encrypt': encrypt,
            'url': encoded,
            'vod_data': {'vod_name': 'Sample movie'},
          })};</script>';
      final dio = Dio()..httpClientAdapter = adapter;
      final source = Site91MdSource(
        baseUrl: 'https://md.example.test',
        dio: dio,
      );
      final detail = await source.fetchDetail('1', forceRefresh: true);
      expect(detail!.video.hlsUrl, url);
      expect(detail.video.title, 'Sample movie');
      expect(detail.video.author, '91麻豆');
      expect(detail.video.detailUrl, contains('/vod/play/id/1/'));
      await source.flushCacheNow();
      dio.close(force: true);
    });
  }
  test(
    'pagination preserves earlier items and retries the same failed page',
    () async {
      final controller = HomeController(_ControllerSource());
      await controller.loadFirstPage();
      await controller.loadMore();
      expect(controller.videos.map((v) => v.id), ['a', 'b']);
      expect(controller.hasMore.value, isTrue);
      expect(controller.loadMoreError.value, isNotNull);
      await controller.loadMore();
      expect(controller.videos.map((v) => v.id), ['a', 'b', 'c']);
      expect(controller.loadMoreError.value, isNull);
      expect(controller.hasMore.value, isFalse);
      controller.onClose();
    },
  );
  test('saved 91md video keeps its source after a platform switch', () {
    final md = Site91MdSource(baseUrl: 'https://mirror.example.test');
    SourceRegistry.register(md);
    const item = VideoItem(
      id: 'https://old.example.test/index.php/vod/play/id/3/sid/1/nid/1.html',
      title: 'Sample',
      author: '91麻豆',
      hlsUrl: '',
    );
    expect(
      SourceRegistry.forVideo(item, fallback: Site91Source()),
      SourceRegistry.byId('site91md'),
    );
    expect(md.ownsItem(item), isTrue);
    final service = UserService();
    service.addVideoToFolder('Saved', item);
    expect(service.isVideoInFolder('Saved', item.id), isTrue);
    expect(
      VideoItem.fromJson(service.favorites['Saved']!.single.toJson()).detailUrl,
      item.detailUrl,
    );
  });
  testWidgets(
    'mobile navigation expands, selects and remains usable on both themes',
    (tester) async {
      tester.view.physicalSize = const Size(360, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final categories = List.generate(
        20,
        (i) => VideoCategory(id: '$i', name: '栏目 $i', path: '/type/$i'),
      );
      VideoCategory? chosen;
      for (final theme in [ThemeData.light(), ThemeData.dark()]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Site91MdCategoryBar(
                key: UniqueKey(),
                categories: categories,
                selectedId: null,
                loading: false,
                error: null,
                onRetry: () {},
                onSelect: (v) {
                  chosen = v;
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('展开'));
        await tester.pumpAndSettle();
        expect(find.text('收起'), findsOneWidget);
        await tester.tap(find.text('栏目 0'));
        await tester.pumpAndSettle();
        expect(chosen?.id, '0');
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('收起'));
        await tester.pumpAndSettle();
        expect(find.text('展开'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
