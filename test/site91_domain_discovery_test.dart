// 自动检测链路的确定性测试（不联网）。
//
// 固件取自真实抓取结果：
//   - test/fixtures/site91/publish_page.html      —— dizhi360.com 的真实响应（JS 空壳）
//   - test/fixtures/site91/publish_script_head.js —— publish.js 的字符串表片段（含明文直连）
//
// 覆盖点：发布页三级查找、直连提取与排序、内容校验（拒绝非 91 页面）、命中即停。
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';

/// 真实站点的最小特征：命中 _looksLikeNinetyOneSite 的标题分支。
///
/// 正文必须撑过 2000 字节 —— `_probeDirectLink` 用长度下限过滤停靠页/错误页，
/// 真实首页约 100KB，这里补足填充即可。
final String _siteHtml =
    '''
<!DOCTYPE html><html><head>
<title>九色|91PORNY|国产自拍|成人视频</title></head>
<body><div class="video-elem"><a href="/view/1816005455">x</a></div>
<!-- ${'padding ' * 300} -->
</body></html>''';

/// 只返回固件的适配器。
///
/// [liveDirectHost] 是唯一「可用」的直连域名，其余直连一律连不上 ——
/// 用来验证探测确实会跳过死域名。
class _FixtureAdapter implements HttpClientAdapter {
  _FixtureAdapter({required this.liveDirectHost, this.livePublishHost});

  final String liveDirectHost;
  final String? livePublishHost;

  /// 记录被请求过的 host，便于断言扫描顺序与命中即停。
  final List<String> requestedHosts = <String>[];

  String pageHtml = '';
  String scriptJs = '';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    final host = uri.host;
    requestedHosts.add(host);
    const headers = <String, List<String>>{
      Headers.contentTypeHeader: ['text/html'],
    };

    if (uri.path.contains('publish.js')) {
      return ResponseBody.fromString(
        scriptJs,
        200,
        headers: const <String, List<String>>{
          Headers.contentTypeHeader: ['text/javascript'],
        },
      );
    }

    if (livePublishHost != null && host == livePublishHost) {
      return ResponseBody.fromString(pageHtml, 200, headers: headers);
    }

    if (host == liveDirectHost) {
      return ResponseBody.fromString(_siteHtml, 200, headers: headers);
    }

    throw DioException(
      requestOptions: options,
      type: DioExceptionType.connectionError,
      error: 'unreachable in fixture',
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String pageHtml;
  late String scriptJs;
  late int candidateCount;

  setUpAll(() {
    pageHtml = File('test/fixtures/site91/publish_page.html')
        .readAsStringSync();
    scriptJs = File('test/fixtures/site91/publish_script_head.js')
        .readAsStringSync();
    // 固件里能提取出的直连候选总数（去重）。断言用它，避免写死数字。
    candidateCount = RegExp(r'91tanhua\d+\.sbs')
        .allMatches(scriptJs)
        .map((m) => m.group(0))
        .toSet()
        .length;
  });

  _FixtureAdapter makeAdapter({
    required String liveDirectHost,
    String? livePublishHost,
  }) {
    return _FixtureAdapter(
        liveDirectHost: liveDirectHost,
        livePublishHost: livePublishHost,
      )
      ..pageHtml = pageHtml
      ..scriptJs = scriptJs;
  }

  test('cached working domain returns without publisher requests', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'site91_last_direct_host': 'https://www.91tanhua343.sbs',
    });
    final adapter = makeAdapter(liveDirectHost: 'www.91tanhua343.sbs');
    final result = await Site91Source(dio: _dioWith(adapter))
        .discoverWorkingDomain();
    expect(result.domain, 'https://www.91tanhua343.sbs');
    expect(result.testedPublishHosts, 0);
    expect(result.testedDirectLinks, 1);
    expect(adapter.requestedHosts, ['www.91tanhua343.sbs']);
  });

  test('unavailable publishers use a small fixed fallback list', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final adapter = makeAdapter(liveDirectHost: 'www.never-alive.example');
    final result = await Site91Source(dio: _dioWith(adapter))
        .discoverWorkingDomain();
    expect(result.found, false);
    expect(result.testedPublishHosts, lessThanOrEqualTo(4));
    expect(adapter.requestedHosts, isNot(contains('dizhi361.com')));
  });

  test('发布页可达时，能提取直连并命中第一个可用域名', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final adapter = makeAdapter(
      liveDirectHost: 'www.91tanhua349.sbs',
      livePublishHost: 'dizhi360.com',
    );
    final source = Site91Source(dio: _dioWith(adapter));

    final stages = <String>[];
    final result = await source.discoverWorkingDomain(
      onProgress: (stage, tested) => stages.add('$stage:$tested'),
    );

    expect(result.found, isTrue, reason: '固件里 91tanhua349.sbs 是唯一可用直连');
    expect(result.domain, 'https://www.91tanhua349.sbs');
    expect(result.publishHost, 'https://dizhi360.com');
    // 种子发布页 968/969 先试，失败后才轮到 360。
    expect(adapter.requestedHosts.take(2), ['dizhi968.com', 'dizhi969.com']);
    expect(adapter.requestedHosts, contains('dizhi360.com'));
    // 命中即停：候选不该被探完。
    expect(
      result.testedDirectLinks,
      2,
      reason: 'only the two candidates before the first success are requested',
    );
    expect(result.testedPublishHosts, 3);
    expect(stages.first, startsWith('publish:'));
    expect(stages.last, startsWith('direct:'));
  });

  test('候选全是死域名时如实返回未找到，而不是拿停靠页充数', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final adapter = makeAdapter(
      liveDirectHost: 'www.never-alive.example',
      livePublishHost: 'dizhi360.com',
    );
    final source = Site91Source(dio: _dioWith(adapter));

    final result = await source.discoverWorkingDomain();

    expect(result.found, isFalse);
    expect(result.publishHost, 'https://dizhi360.com');
    // 只尝试少量候选后回退手动配置，不穷举全部地址。
    expect(result.testedDirectLinks, 8);
    expect(result.testedDirectLinks, lessThan(candidateCount));
  });

  test('发布页全部不可达时不挂起，且不产生域名', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final adapter = makeAdapter(liveDirectHost: 'www.91tanhua343.sbs');
    final source = Site91Source(dio: _dioWith(adapter));

    final sw = Stopwatch()..start();
    final result = await source.discoverWorkingDomain();
    sw.stop();

    expect(result.found, isFalse);
    expect(result.domain, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('记住上次成功的发布页，下次第一个就试它', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'site91_last_publish_host': 'https://dizhi960.com',
    });
    final adapter = makeAdapter(
      liveDirectHost: 'www.91tanhua349.sbs',
      livePublishHost: 'dizhi960.com',
    );
    final source = Site91Source(dio: _dioWith(adapter));

    final result = await source.discoverWorkingDomain();

    expect(result.publishHost, 'https://dizhi960.com');
    expect(adapter.requestedHosts.first, 'dizhi960.com');
  });
}

Dio _dioWith(HttpClientAdapter adapter) {
  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 2),
      receiveTimeout: const Duration(seconds: 2),
    ),
  );
  dio.httpClientAdapter = adapter;
  return dio;
}
