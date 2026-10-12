import 'package:video_browser/app/modules/pornhub/views/pornhub_more_page.dart';
import 'package:video_browser/app/modules/pornhub/pornhub_controller.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_video_info_panel.dart';

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_browse_page.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_playlist_page.dart';
import 'package:video_browser/app/routes/app_navigator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/models/pornhub_models.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/pornhub_source.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_search_page.dart';
import 'package:video_browser/app/modules/pornhub/views/pornhub_creator_page.dart';
import 'package:video_browser/app/modules/pornhub/widgets/pornhub_video_grid.dart';
import 'package:video_browser/app/modules/search/search_view.dart';
import 'package:video_browser/app/services/user_service.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/widgets/bili_video_card.dart';

class Navigation91Source extends Site91Source {
  final queries = <String>[];
  @override
  Future<List<String>> fetchHotKeywords() async => [];
  @override
  Future<VideoPage> search({
    required SearchQuery query,
    required int page,
    int pageSize = 12,
  }) async {
    queries.add(query.keyword);
    return const VideoPage.empty();
  }

  @override
  Future<VideoDetail> fetchDetail(
    String videoId, {
    bool forceRefresh = false,
  }) async => VideoDetail(video: fixture);
}

class NavigationPhSource extends PornHubSource {
  final browse = <({String path, int page, String kind})>[];
  final profiles = <String>[];
  final videos = <String>[];
  @override
  Future<PornHubBrowseData> fetchBrowse(
    String path, {
    int page = 1,
    String kind = 'videos',
  }) async {
    browse.add((path: path, page: page, kind: kind));
    return browseResponse;
  }

  @override
  Future<PornHubCreatorProfile> fetchCreatorProfile(String path) async {
    profiles.add(path);
    return PornHubCreatorProfile(
      path: path,
      name: 'Fixture Author',
      videoCount: 0,
    );
  }

  @override
  Future<VideoPage> fetchCreatorVideos(String path, {int page = 1}) async {
    videos.add(path);
    return const VideoPage.empty();
  }

  PornHubDetailExtra extra = const PornHubDetailExtra();
  @override
  Future<PornHubDetailExtra> fetchDetailExtra(
    String videoId, {
    bool forceRefresh = false,
  }) async => extra;
  PornHubBrowseData browseResponse = const PornHubBrowseData();
  final categoryRequests = <String>[];
  final starRequests = <String>[];
  final playlistVideoRequests = <String>[];
  @override
  Future<VideoPage> fetchPathPage(String path, int page) async {
    categoryRequests.add(path);
    return const VideoPage.empty();
  }

  @override
  Future<List<PornHubPlaylist>> fetchPlaylists({
    int page = 1,
    String path = '/playlists?o=mr',
  }) async => const [
    PornHubPlaylist(id: '123', title: 'Fixture playlist', url: '/playlist/123'),
  ];
  @override
  Future<List<PornHubStar>> fetchStars({int page = 1}) async => const [
    PornHubStar(name: 'Fixture Star', url: '/pornstar/fixture-star'),
  ];
  @override
  Future<VideoPage> fetchStarVideos(String name, {int page = 1}) async {
    starRequests.add(name);
    return const VideoPage.empty();
  }

  final playlistRequests = <String>[];
  @override
  Future<PornHubPlaylistDetails> fetchPlaylistDetails(
    String id, {
    bool forceRefresh = false,
  }) async {
    playlistRequests.add(id);
    return PornHubPlaylistDetails(
      playlist: PornHubPlaylist(
        id: id,
        title: 'Fixture playlist',
        url: '/playlist/$id',
      ),
    );
  }

  @override
  Future<VideoPage> fetchPlaylistVideos(String id, {int page = 1}) async {
    playlistVideoRequests.add(id);
    return const VideoPage.empty();
  }

  @override
  Future<VideoPage> fetchCreatorClips(String path, {int page = 1}) async =>
      const VideoPage.empty();
}

class CardHtmlAdapter implements HttpClientAdapter {
  CardHtmlAdapter(this.html);
  final String html;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async => ResponseBody.fromString(
    '$html<!--${'x' * 10001}-->',
    200,
    headers: {
      'content-type': ['text/html'],
    },
  );
  @override
  void close({bool force = false}) {}
}

const fixture = VideoItem(
  id: 'fixture-key',
  title: 'Neutral card',
  author: 'Fixture Author',
  hlsUrl: '',
  detailUrl: 'https://cn.pornhub.com/view_video.php?viewkey=fixture-key',
);
void main() {
  final site91 = Navigation91Source(), ph = NavigationPhSource();
  SourceRegistry.register(site91);
  SourceRegistry.register(ph);
  late int preload;
  setUp(() {
    Get.testMode = true;
    Get.put<VideoSource>(site91, permanent: true);
    Get.put(UserService(), permanent: true);
    SourceRegistry.setActiveSource(site91);
    site91.queries.clear();
    ph.browse.clear();
    ph.profiles.clear();
    ph.videos.clear();
    ph.playlistRequests.clear();
    ph.playlistVideoRequests.clear();
    ph.categoryRequests.clear();
    ph.starRequests.clear();
    ph.browseResponse = const PornHubBrowseData();
    ph.extra = const PornHubDetailExtra();
    preload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
  });
  tearDown(() {
    Get.reset();
    PreloadService.instance.preloadCount.value = preload;
  });
  Future<void> mount(
    WidgetTester tester,
    VideoItem video, {
    bool horizontal = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: horizontal
              ? BiliVideoCardH(video: video)
              : CustomScrollView(
                  slivers: [
                    SliverPornHubGrid(videos: [video]),
                  ],
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final horizontal in [false, true]) {
    testWidgets(
      'PH ${horizontal ? 'horizontal' : 'grid'} author fallback stays in PH with global91',
      (tester) async {
        await mount(tester, fixture, horizontal: horizontal);
        await tester.tap(find.text('Fixture Author'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchView), findsNothing);
        expect(find.byType(PornHubSearchPage), findsOneWidget);
        expect(site91.queries, isEmpty);
        expect(ph.browse.single.kind, 'creators');
        expect(
          Uri.parse(ph.browse.single.path).queryParameters['username'],
          'Fixture Author',
        );
      },
    );
  }
  for (final link in [
    '/model/fixture-slug',
    'https://www.pornhub.com/pornstar/fixture-slug',
    '/channels/fixture-slug',
  ]) {
    testWidgets('PH author follows actual uploader link $link', (tester) async {
      final video = VideoItem.fromJson({
        ...fixture.toJson(),
        'authorUrl': link,
      });
      await mount(tester, video);
      await tester.tap(find.text('Fixture Author'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchView), findsNothing);
      expect(find.byType(PornHubCreatorPage), findsOneWidget);
      expect(
        tester.widget<PornHubCreatorPage>(find.byType(PornHubCreatorPage)).path,
        Uri.parse(link).path,
      );
      expect(site91.queries, isEmpty);
      expect(ph.profiles.single, Uri.parse(link).path);
    });
  }
  test('author link survives model copy and serialization; old records stay nullable', () {
    final video = VideoItem.fromJson({
      ...fixture.toJson(),
      'authorUrl': '/model/fixture-slug',
    });
    expect(
      video.copyWith(title: 'Changed').toJson()['authorUrl'],
      '/model/fixture-slug',
    );
    expect(VideoItem.fromJson(fixture.toJson()).toJson()['authorUrl'], isNull);
  });
  testWidgets('91 card author keeps original 91 search', (tester) async {
    final video = fixture.copyWith(
      detailUrl: 'https://91porny.com/video/fixture',
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 240,
            child: BiliVideoCardV(video: video),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture Author'));
    await tester.pumpAndSettle();
    expect(find.byType(SearchView), findsOneWidget);
    expect(find.byType(PornHubSearchPage), findsNothing);
    expect(site91.queries, ['Fixture Author']);
    expect(ph.browse, isEmpty);
  });
  for (final clip in [false, true]) {
    test(
      'original ${clip ? 'clip' : 'video'} parsing retains uploader href without changing fields',
      () async {
        final endpoint = clip ? 'view_clip.php' : 'view_video.php';
        final html =
            '<ul><li data-video-vkey="fixture"><a href="/$endpoint?viewkey=fixture" title="Neutral title">Neutral</a><div class="usernameWrap"><a href="/model/real-slug">Fixture Author</a></div></li></ul>';
        final source = PornHubSource(
          dio: Dio()..httpClientAdapter = CardHtmlAdapter(html),
        );
        final result = await source.fetchBrowse('/video/search?search=fixture');
        final video = result.videos.single;
        expect(video.author, 'Fixture Author');
        expect(video.title, 'Neutral title');
        expect(video.toJson()['authorUrl'], '/model/real-slug');
        expect(
          video.detailUrl,
          'https://cn.pornhub.com/$endpoint?viewkey=fixture',
        );
      },
    );
  }
  testWidgets('PH tag/category browse retains path parameters and own source', (
    tester,
  ) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: TextButton(
            onPressed: () => Get.to<void>(
              () => const PornHubBrowsePage(
                title: 'Fixture category',
                path: '/video/search?search=fixture&o=mr&c=241',
              ),
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(PornHubSearchPage), findsOneWidget);
    expect(find.byType(SearchView), findsNothing);
    expect(Uri.parse(ph.browse.single.path).queryParameters, {
      'search': 'fixture',
      'o': 'mr',
      'c': '241',
    });
    expect(site91.queries, isEmpty);
  });
  for (final path in [
    '/playlist/123?token=fixture',
    'https://cn.pornhub.com/playlist/123',
  ]) {
    testWidgets('PH playlist browse opens actual id $path', (tester) async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: TextButton(
              onPressed: () => Get.to<void>(
                () => PornHubBrowsePage(title: 'Fixture playlist', path: path),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(PornHubPlaylistPage), findsOneWidget);
      expect(
        tester.widget<PornHubPlaylistPage>(find.byType(PornHubPlaylistPage)).id,
        '123',
      );
      expect(ph.playlistRequests, ['123']);
      expect(site91.queries, isEmpty);
      expect(ph.browse, isEmpty);
    });
  }
  testWidgets('PH invalid or foreign author link uses PH creator search', (
    tester,
  ) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: TextButton(
            onPressed: () => AppNavigator.toPornHubAuthor(
              'Fixture Author',
              path: 'https://outside.example/model/fixture',
            ),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(PornHubSearchPage), findsOneWidget);
    expect(ph.browse.single.kind, 'creators');
    expect(ph.profiles, isEmpty);
    expect(site91.queries, isEmpty);
  });
  testWidgets(
    'PH long press all-works menu retains author navigation context',
    (tester) async {
      final video = VideoItem.fromJson({
        ...fixture.toJson(),
        'authorUrl': '/model/fixture-slug',
      });
      await mount(tester, video);
      await tester.longPress(find.text('Fixture Author'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看 TA 的全部作品'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchView), findsNothing);
      expect(find.byType(PornHubCreatorPage), findsOneWidget);
      expect(ph.profiles, ['/model/fixture-slug']);
      expect(site91.queries, isEmpty);
    },
  );
  for (final path in ['/user/fixture', '/channel/fixture']) {
    testWidgets(
      'unsupported singular uploader path falls back within PH $path',
      (tester) async {
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(
              body: TextButton(
                onPressed: () =>
                    AppNavigator.toPornHubAuthor('Fixture Author', path: path),
                child: const Text('Open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.byType(PornHubSearchPage), findsOneWidget);
        expect(find.byType(PornHubCreatorPage), findsNothing);
        expect(ph.profiles, isEmpty);
        expect(ph.browse.single.kind, 'creators');
        expect(site91.queries, isEmpty);
      },
    );
  }
  for (final knownPath in [false, true]) {
    testWidgets(
      'PH detail works ${knownPath ? 'actual uploader' : 'fallback'} never uses 91',
      (tester) async {
        ph.extra = PornHubDetailExtra(
          creatorPath: knownPath ? '/users/fixture' : '',
        );
        await tester.pumpWidget(
          GetMaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: PornHubVideoInfoPanel(
                  video: fixture,
                  onDownload: () {},
                  onPlayVideo: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('作品'));
        await tester.pumpAndSettle();
        expect(find.byType(SearchView), findsNothing);
        expect(site91.queries, isEmpty);
        if (knownPath) {
          expect(find.byType(PornHubCreatorPage), findsOneWidget);
          expect(ph.profiles, ['/users/fixture']);
        } else {
          expect(find.byType(PornHubSearchPage), findsOneWidget);
          expect(ph.browse.single.kind, 'creators');
        }
      },
    );
  }
  testWidgets(
    'PH related card stays in PH even when old metadata lacks detail URL',
    (tester) async {
      ph.extra = const PornHubDetailExtra(
        related: [
          VideoItem(
            id: 'related',
            title: 'Related neutral',
            author: 'Related Author',
            hlsUrl: '',
          ),
        ],
      );
      await tester.pumpWidget(
        GetMaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PornHubVideoInfoPanel(
                video: fixture,
                onDownload: () {},
                onPlayVideo: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Related Author'));
      await tester.tap(find.text('Related Author'));
      await tester.pumpAndSettle();
      expect(find.byType(SearchView), findsNothing);
      expect(find.byType(PornHubSearchPage), findsOneWidget);
      expect(ph.browse.single.kind, 'creators');
      expect(site91.queries, isEmpty);
    },
  );
  testWidgets('PH creator search row uses actual path with global91', (
    tester,
  ) async {
    ph.browseResponse = const PornHubBrowseData(
      creators: [
        PornHubSubscription(name: 'Fixture result', path: '/users/result'),
      ],
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: const PornHubSearchPage(
          initialKeyword: 'fixture',
          initialKind: 'creators',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture result'));
    await tester.pumpAndSettle();
    expect(find.byType(PornHubCreatorPage), findsOneWidget);
    expect(ph.profiles, ['/users/result']);
    expect(site91.queries, isEmpty);
  });
  testWidgets('PH playlist search card uses actual id with global91', (
    tester,
  ) async {
    ph.browseResponse = const PornHubBrowseData(
      playlists: [
        PornHubPlaylist(
          id: '123',
          title: 'Fixture playlist',
          url: '/playlist/123',
        ),
      ],
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: const PornHubSearchPage(
          initialKeyword: 'fixture',
          initialKind: 'playlists',
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fixture playlist'));
    await tester.pumpAndSettle();
    expect(find.byType(PornHubPlaylistPage), findsOneWidget);
    expect(ph.playlistRequests, ['123']);
    expect(ph.playlistVideoRequests, ['123']);
    expect(site91.queries, isEmpty);
  });
  testWidgets('PH detail tag retains its browse query within PH', (
    tester,
  ) async {
    ph.extra = const PornHubDetailExtra(
      tags: [
        PornHubLinkItem(
          name: 'Fixture tag',
          path: '/video/search?search=fixture&o=mr',
        ),
      ],
    );
    await tester.pumpWidget(
      GetMaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: PornHubVideoInfoPanel(
              video: fixture,
              onDownload: () {},
              onPlayVideo: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Fixture tag'));
    await tester.tap(find.text('Fixture tag'));
    await tester.pumpAndSettle();
    expect(find.byType(PornHubSearchPage), findsOneWidget);
    expect(Uri.parse(ph.browse.single.path).queryParameters, {
      'search': 'fixture',
      'o': 'mr',
    });
    expect(site91.queries, isEmpty);
  });
  for (final index in [0, 1, 2]) {
    testWidgets(
      'PH more category/playlist/star entry $index retains PH fetcher',
      (tester) async {
        Get.put(PornHubController(ph), permanent: true);
        await tester.pumpWidget(
          GetMaterialApp(home: PornHubMorePage(initialIndex: index)),
        );
        await tester.pumpAndSettle();
        final label = index == 0
            ? PornHubCategories.categoryList.first.name
            : index == 1
            ? 'Fixture playlist'
            : 'Fixture Star';
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
        expect(find.byType(SearchView), findsNothing);
        expect(site91.queries, isEmpty);
        if (index == 0) {
          expect(ph.categoryRequests, [
            PornHubCategories.categoryList.first.path,
          ]);
        }
        if (index == 1) {
          expect(ph.playlistVideoRequests, ['123']);
        }
        if (index == 2) {
          expect(ph.starRequests, ['Fixture Star']);
        }
      },
    );
  }
}
