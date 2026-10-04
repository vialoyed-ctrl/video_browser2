import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:video_browser/app/services/hanime1_auth_service.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';

void main() {
  setUp(() => Get.put(Hanime1AuthService()));
  tearDown(() => Get.reset());
  test('coalesces identical list requests and reuses recent results', () async {
    var requests = 0;
    final release = Completer<void>();
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            requests++;
            await release.future;
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<div class="studio-card"><a href="/search?query=Sample"><img src="/logo.png">Sample</a><div>3 个视频</div></div>',
              ),
            );
          },
        ),
      );
    final source = Hanime1Source(dio: dio);
    const query = SearchQuery(searchType: SearchType.authorId);
    final first = source.search(query: query, page: 1);
    final second = source.search(query: query, page: 1);
    release.complete();
    final results = await Future.wait([first, second]);
    expect(results.first.items, hasLength(1));
    expect(requests, 1);
    await source.search(query: query, page: 1);
    expect(requests, 1);
    await source.search(query: query, page: 2);
    expect(
      requests,
      2,
      reason: 'Different pages must never share cached results',
    );
  });
  test('preserves Hanime1 filters using the official date parameter', () async {
    Uri? requested;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested = options.uri;
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '<ul class="pagination"><li><a href="?page=3">3</a></li></ul>',
              ),
            );
          },
        ),
      );

    await Hanime1Source(dio: dio).search(
      query: const SearchQuery(
        keyword: 'sample title',
        category: '泡麵番',
        sortParam: '觀看次數',
        time: '2024 年 9 月',
        duration: '5 分鐘 +',
        tags: ['無碼', '1080p'],
        tagBroad: true,
      ),
      page: 2,
    );

    expect(requested?.path, '/search');
    expect(requested?.queryParameters['query'], 'sample title');
    expect(requested?.queryParameters['genre'], '泡麵番');
    expect(requested?.queryParameters['sort'], '觀看次數');
    expect(requested?.queryParameters['date'], '2024 年 9 月');
    expect(requested?.queryParameters.containsKey('year'), isFalse);
    expect(requested?.queryParameters.containsKey('month'), isFalse);
    expect(requested?.queryParameters['duration'], '5 分鐘 +');
    expect(requested?.queryParametersAll['tags[]'], ['無碼', '1080p']);
    expect(requested?.queryParameters['broad'], 'on');
    expect(requested?.queryParameters['page'], '2');
  });

  test('loads official studio directory cards in artist mode', () async {
    Uri? requested;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested = options.uri;
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''
                  <div class="studio-card">
                    <a href="/search?query=HSCK&genre=">
                      <img src="/logos/hsck.png" alt="HSCK">
                      <span>HSCK</span>
                    </a>
                    <div>47890 个视频</div>
                  </div>
                  <ul class="pagination"><li><a href="?page=60">60</a></li></ul>
                ''',
              ),
            );
          },
        ),
      );

    final page = await Hanime1Source(dio: dio).search(
      query: const SearchQuery(searchType: SearchType.authorId),
      page: 1,
    );

    expect(requested?.queryParameters['type'], 'artist');
    expect(page.totalPages, 60);
    expect(page.items, hasLength(1));
    expect(page.items.single.title, 'HSCK');
    expect(page.items.single.thumbnailUrl, 'https://hanime1.me/logos/hsck.png');
    expect(page.items.single.viewsStr, '47890 个视频');
  });

  test('reads every official category and preserves its query value', () async {
    const html = '''
      <div class="home-genre-tabs-wrapper">
        <a href="https://hanime1.me/search?genre=裏番">里番</a>
      </div>
      <div class="home-genre-tabs-wrapper">
        <a href="https://hanime1.me/search?genre=泡麵番">泡面番</a>
      </div>
      <div class="home-genre-tabs-wrapper">
        <a href="/search?genre=Motion%20Anime">Motion Anime</a>
      </div>
      <div class="home-genre-tabs-wrapper">
        <a href="https://other.example/search?genre=外部">外部</a>
      </div>
      <div id="home-banner-wrapper"><h1>Untargeted hero</h1></div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );

    final data = await Hanime1Source(dio: dio).fetchHomeStructured();

    expect(data, isNotNull);
    expect(data!.genreTabs, ['里番', '泡面番', 'Motion Anime']);
    expect(data.genreValues, {
      '里番': '裏番',
      '泡面番': '泡麵番',
      'Motion Anime': 'Motion Anime',
    });
    expect(data.hero, isNull);
  });

  test(
    'parses the official search card layout used by genre and ranking',
    () async {
      const html = '''
      <div class="search-rows-wrapper">
        <div class="home-rows-videos-wrapper">
          <a href="https://hanime1.me/watch?v=408225">
            <div class="home-rows-videos-div search-videos">
              <img src="https://example.com/cover.jpg">
              <div class="home-rows-videos-title">泡麵番測試 1</div>
            </div>
          </a>
          <a href="https://hanime1.me/watch?v=408225">duplicate</a>
          <a href="https://external.example/ad">advertisement</a>
        </div>
      </div>
      <ul class="pagination">
        <li><a href="/search?page=1">1</a></li>
        <li><a href="/search?page=2">2</a></li>
        <li><a href="/search?page=17">17</a></li>
        <li><a rel="next" href="/search?page=2">›</a></li>
      </ul>
    ''';
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: html,
              ),
            ),
          ),
        );

      final page = await Hanime1Source(dio: dio).fetchRankingList('本日排行');

      expect(page.items, hasLength(1));
      expect(page.items.single.id, '408225');
      expect(page.items.single.title, '泡麵番測試 1');
      expect(page.items.single.thumbnailUrl, 'https://example.com/cover.jpg');
      expect(page.totalPages, 17);
    },
  );

  test('subscription filters use the site form parameter names', () async {
    Uri? requested;
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            requested = options.uri;
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: '''
                <ul class="pagination">
                  <li><a href="/subscriptions?page=1">1</a></li>
                  <li><a href="/subscriptions?page=2">2</a></li>
                  <li><a href="/subscriptions?page=9">9</a></li>
                  <li><a rel="next" href="/subscriptions?page=3">›</a></li>
                </ul>
              ''',
              ),
            );
          },
        ),
      );

    final pageData = await Hanime1Source(dio: dio).fetchSubscriptionsData(
      page: 2,
      query: 'NT00',
      genre: '泡麵番',
      sort: '本日排行',
      date: '過去 1 週',
      duration: '5 分鐘 +',
      tags: ['無碼', '1080p'],
      broad: true,
    );

    expect(requested?.path, '/subscriptions');
    expect(requested?.queryParameters['query'], 'NT00');
    expect(requested?.queryParameters['genre'], '泡麵番');
    expect(requested?.queryParameters['sort'], '本日排行');
    expect(requested?.queryParameters['date'], '過去 1 週');
    expect(requested?.queryParameters['duration'], '5 分鐘 +');
    expect(requested?.queryParametersAll['tags[]'], ['無碼', '1080p']);
    expect(requested?.queryParameters['broad'], 'on');
    expect(requested?.queryParameters['page'], '2');
    expect(pageData.totalPages, 9);
  });

  test('parses a user playlist page into playable video rows', () async {
    const html = '''
      <div class="playlist-flex-wrapper">
        <img class="playlist-main-thumbnail" src="https://example.com/list.jpg">
        <h1 class="playlist-title">清單標題</h1>
        <div class="playlist-author-info">
          <a href="https://hanime1.me/user/100001">example_user</a>
        </div>
        <p class="playlist-stats">播放清單 • 2 部影片 • 觀看次數：123 次</p>
        <div class="playlist-video-list">
          <a class="filter-pill active" href="/playlist?list=123&sort=latest">最新</a>
          <div class="playlist-video-card video-item-container">
            <div class="video-thumb-container horizontal-card">
              <div class="thumb-container">
                <a href="https://hanime1.me/watch?v=408443&list=123&sort=latest">
                  <img class="main-thumb" src="https://example.com/video.jpg">
                  <div class="duration">04:12</div>
                  <div class="stats-container">
                    <div class="stat-item">100%</div>
                    <div class="stat-item">12.3萬次</div>
                  </div>
                </a>
              </div>
            </div>
            <div class="video-info-container">
              <h4 class="video-title"><a href="/watch?v=408443&list=123">作品標題</a></h4>
              <div class="meta-author"><a>作者名稱</a></div>
              <div class="meta-stats"><span>3年前</span></div>
            </div>
          </div>
          <a rel="next" href="/playlist?list=123&page=3">下一頁</a>
        </div>
      </div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );

    final page = await Hanime1Source(dio: dio)
        .fetchPlaylist('123', sort: 'popular', page: 2);

    expect(page, isNotNull);
    expect(page!.title, '清單標題');
    expect(page.creator, 'example_user');
    expect(page.videoCount, '2');
    expect(page.viewsText, '123 次');
    expect(page.sort, 'latest');
    expect(page.hasMore, isTrue);
    expect(page.totalPages, 3);
    expect(page.items, hasLength(1));
    expect(page.items.single.id, '408443');
    expect(page.items.single.title, '作品標題');
    expect(page.items.single.author, '作者名稱');
    expect(page.items.single.thumbnailUrl, 'https://example.com/video.jpg');
  });

  test('parses playlist cards in the official user playlists tab', () async {
    const html = '''
      <div class="playlist-holder">
        <a href="/playlist?list=38158">
          <img src="https://example.com/list.jpg">
          <i>playlist_play</i>
          <span>1 部影片</span>
          <span>荒木英樹</span>
        </a>
      </div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );

    final page = await Hanime1Source(dio: dio).fetchChannelPage(
      channel: ChannelType.vod,
      categoryPath: '/user/100001/playlists',
      page: 1,
    );

    expect(page.items, hasLength(1));
    expect(page.items.single.id, 'pl_38158');
    expect(page.items.single.title, '荒木英樹');
    expect(page.items.single.viewsStr, '1 部影片');
    expect(
      page.items.single.detailUrl,
      'https://hanime1.me/playlist?list=38158',
    );
  });

  test('uses the opened user playlist as playback context', () async {
    const playlistHtml = '''
      <div class="playlist-flex-wrapper">
        <h1 class="playlist-title">我的清單</h1>
        <div class="playlist-author-info"><a href="/user/100001">example_user</a></div>
        <div class="playlist-video-list">
          <div class="playlist-video-card video-item-container">
            <a class="video-link" href="/watch?v=408443&list=123">
              <img class="main-thumb" src="https://example.com/list-video.jpg">
              <div class="title">清單內作品</div>
            </a>
          </div>
        </div>
      </div>
    ''';
    const watchHtml = '''
      <h3 id="shareBtn-title">清單內作品</h3>
      <video id="player"><source src="https://example.com/video.mp4" size="720"></video>
      <div id="playlist-top-block"><h4><a href="/playlist?list=creator">作者系列</a></h4></div>
      <div id="playlist-scroll">
        <div class="video-item-container"><a class="video-link" href="/watch?v=999"><div class="title">作者系列作品</div></a></div>
      </div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: options.uri.path == '/playlist' ? playlistHtml : watchHtml,
            ),
          ),
        ),
      );
    final source = Hanime1Source(dio: dio);

    final openedPlaylist = await source.fetchPlaylist('123');
    expect(openedPlaylist?.title, '我的清單');
    final detail = await source.fetchDetail(
      'https://hanime1.me/watch?v=408443&list=123',
    );

    expect(detail, isNotNull);
    final extra = source.getExtra('408443');
    expect(extra?.playlistTitle, '我的清單');
    expect(extra?.playlistPath, '/playlist?list=123');
    expect(extra?.playlistAuthor, 'example_user');
    expect(extra?.playlistItems.map((item) => item.id), ['408443']);
  });

  test('uses the visible watch title before caption metadata', () async {
    const html = '''
      <h3 id="shareBtn-title">[NT00] マチュLive2D</h3>
      <div class="video-caption-text">Title / タイトル: Different original name</div>
      <video id="player"><source src="https://example.com/video.mp4" size="720"></video>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );

    final detail = await Hanime1Source(dio: dio).fetchDetail('407643');

    expect(detail?.video.title, '[NT00] マチュLive2D');
  });

  test('normalizes the hash prefix from query-style video tags', () async {
    const html = '''
      <h3 id="shareBtn-title">作品标题</h3>
      <video id="player"><source src="https://example.com/video.mp4" size="720"></video>
      <div class="video-tags-wrapper">
        <div class="single-video-tag">
          <a href="/search?query=Final%20Fantasy"># Final Fantasy最終幻想系列</a>
        </div>
      </div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );
    final source = Hanime1Source(dio: dio);

    await source.fetchDetail('407643');

    expect(source.getExtra('407643')?.tags.single.name, 'Final Fantasy最終幻想系列');
  });

  test(
    'shares a pending watch-page request between prefetch and playback',
    () async {
      const html = '''
      <h3 id="shareBtn-title">作品标题</h3>
      <video id="player"><source src="https://example.com/video.mp4" size="720"></video>
      <div id="related-tabcontent"></div>
    ''';
      final requestStarted = Completer<void>();
      final releaseResponse = Completer<void>();
      var requestCount = 0;
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) async {
              requestCount++;
              if (!requestStarted.isCompleted) requestStarted.complete();
              await releaseResponse.future;
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: html,
                ),
              );
            },
          ),
        );
      final source = Hanime1Source(dio: dio);

      final prefetch = source.fetchDetail('407643');
      await requestStarted.future;
      final playback = source.fetchDetail('https://hanime1.me/watch?v=407643');
      releaseResponse.complete();
      await Future.wait([prefetch, playback]);

      expect(requestCount, 1);
    },
  );

  test('keeps related HTML for the whole prefetched first screen', () async {
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            final id = options.uri.queryParameters['v'] ?? '0';
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data:
                    '''
                  <h3 id="shareBtn-title">作品 $id</h3>
                  <video id="player"><source src="https://example.com/$id.mp4" size="720"></video>
                  <div id="related-tabcontent">
                    <div class="video-item-container">
                      <a class="video-link" href="/watch?v=5$id">
                        <div class="title">相关推荐 $id</div>
                      </a>
                    </div>
                  </div>
                ''',
              ),
            );
          },
        ),
      );
    final source = Hanime1Source(dio: dio);

    for (final id in ['407643', '407644', '407645', '407646']) {
      await source.fetchDetail(id);
    }

    final firstRelated = await source.fetchRelatedVideos('407643');
    expect(firstRelated, hasLength(1));
    expect(firstRelated.single.id, '5407643');
  });

  test(
    'defers related card parsing until after watch detail is returned',
    () async {
      const html = '''
      <h3 id="shareBtn-title">主影片</h3>
      <video id="player"><source src="https://example.com/video.mp4" size="720"></video>
      <div id="playlist-scroll">
        <div class="video-item-container">
          <a class="video-link" href="/watch?v=407645">
            <img class="main-thumb" src="https://example.com/series.jpg">
            <div class="title">系列影片，不应混入相关推荐</div>
          </a>
        </div>
      </div>
      <div id="related-tabcontent">
        <div class="video-item-container">
          <a class="video-link" href="/watch?v=407644">
            <img class="main-thumb" src="https://example.com/related.jpg">
            <div class="title">相關影片</div>
          </a>
        </div>
        <div class="video-item-container">
          <a class="video-link" href="/watch?v=407643">
            <div class="title">当前影片，不应重复</div>
          </a>
        </div>
      </div>
      <div class="video-item-container">
        <a class="video-link" href="/watch?v=407646">
          <div class="title">页面其他区域，不应混入相关推荐</div>
        </a>
      </div>
    ''';
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) => handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 200,
                data: html,
              ),
            ),
          ),
        );
      final source = Hanime1Source(dio: dio);

      final detail = await source.fetchDetail('407643');
      expect(detail?.relatedVideos, isEmpty);

      final related = await source.fetchRelatedVideos('407643');
      expect(related, hasLength(1));
      expect(related.single.id, '407644');
      expect(related.single.title, '相關影片');
    },
  );

  test('reports the visible official user-page number range', () async {
    const html = '''
      <div class="specific-tab-view"></div>
      <div class="search-pagination user-items-pagination">
        <ul class="pagination">
          <li class="active"><span class="page-link">1</span></li>
          <li><a href="/user/100001/histories?page=2">2</a></li>
          <li><a href="/user/100001/histories?page=12">12</a></li>
          <li><a rel="next" href="/user/100001/histories?page=2">›</a></li>
        </ul>
      </div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<String>(
              requestOptions: options,
              statusCode: 200,
              data: html,
            ),
          ),
        ),
      );

    final page = await Hanime1Source(dio: dio)
        .fetchUserTabPage('100001', 'histories');
    expect(page.totalPages, 12);
    expect(page.hasMore, isTrue);
  });

  test('reads comment HTML from a decoded JSON response', () async {
    const fragment = '''
      <a><img src="https://example.com/avatar.jpg"></a>
      <div class="report-btn-wrapper">
        <div class="comment-index-text"><a>Viewer</a><span>1日前</span></div>
        <div class="comment-index-text">A comment</div>
        <button data-reportable-id="123"></button>
      </div>
      <div><span>thumb_up</span><span>2</span></div>
    ''';
    final dio = Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {'comments': fragment},
            ),
          ),
        ),
      );

    final comments = await Hanime1Source(dio: dio).fetchComments('407643');

    expect(comments, hasLength(1));
    expect(comments.single.commentId, '123');
    expect(comments.single.body, 'A comment');
  });
}
