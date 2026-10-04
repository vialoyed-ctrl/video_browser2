/// 纯逻辑单元测试。
///
/// 只覆盖不依赖平台通道的部分：m3u8 解析、文件名清洗、代理 URL 生成。
/// 播放与文件下载依赖原生库，不在单元测试范围内。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/services/hls_cache_proxy.dart';
import 'package:video_browser/app/services/hls_parser.dart';
import 'package:video_browser/app/services/preload_service.dart';

void main() {
  group('HlsParser - media playlist', () {
    const content = '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:6
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
seg0.m4s
#EXTINF:6.0,
seg1.m4s
#EXT-X-ENDLIST
''';

    test('解析出 init segment 与全部分片，并解析为绝对地址', () {
      final playlist = HlsParser.parse(
        content,
        Uri.parse('https://cdn.example.com/vod/720p/index.m3u8'),
      );

      expect(playlist.isMaster, isFalse);
      expect(playlist.isFragmentedMp4, isTrue);
      expect(playlist.outputExtension, '.mp4');
      expect(
        playlist.initSegment.toString(),
        'https://cdn.example.com/vod/720p/init.mp4',
      );
      expect(playlist.segments.length, 2);
      expect(
        playlist.segments.first.toString(),
        'https://cdn.example.com/vod/720p/seg0.m4s',
      );
      expect(playlist.durationSeconds, closeTo(12.0, 0.001));
      expect(playlist.totalParts, 3);
    });

    test('纯 TS 流输出扩展名为 .ts', () {
      const tsContent = '''
#EXTM3U
#EXTINF:6.0,
a.ts
#EXTINF:6.0,
b.ts
''';
      final playlist = HlsParser.parse(
        tsContent,
        Uri.parse('https://cdn.example.com/hls/index.m3u8'),
      );
      expect(playlist.isFragmentedMp4, isFalse);
      expect(playlist.outputExtension, '.ts');
      expect(playlist.totalParts, 2);
    });

    test('识别 AES-128 加密', () {
      const encrypted = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:6.0,
a.ts
''';
      final playlist = HlsParser.parse(
        encrypted,
        Uri.parse('https://cdn.example.com/hls/index.m3u8'),
      );
      expect(playlist.isEncrypted, isTrue);
      expect(playlist.encryptionMethod, 'AES-128');
      expect(
        playlist.encryptionKeyUri.toString(),
        'https://cdn.example.com/hls/key.bin',
      );
    });

    test('空内容与非法头部抛出 HlsParseException', () {
      expect(
        () => HlsParser.parse('', Uri.parse('https://x/y.m3u8')),
        throwsA(isA<HlsParseException>()),
      );
      expect(
        () => HlsParser.parse('<html></html>', Uri.parse('https://x/y.m3u8')),
        throwsA(isA<HlsParseException>()),
      );
    });
  });

  group('HlsParser - master playlist', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
1080/index.m3u8
''';

    test('识别 master 并解析全部变体', () {
      final playlist = HlsParser.parse(
        master,
        Uri.parse('https://cdn.example.com/vod/master.m3u8'),
      );
      expect(playlist.isMaster, isTrue);
      expect(playlist.variants.length, 3);
      expect(playlist.variants.first.resolution, '640x360');
      expect(
        playlist.variants.first.uri.toString(),
        'https://cdn.example.com/vod/360/index.m3u8',
      );
    });

    test('pickBest 返回最高码率的一路', () {
      final playlist = HlsParser.parse(
        master,
        Uri.parse('https://cdn.example.com/vod/master.m3u8'),
      );
      final best = HlsParser.pickBest(playlist.variants);
      expect(best.resolution, '1920x1080');
      expect(best.bandwidth, 6000000);
      expect(best.label, '1920x1080');
    });
  });

  group('VideoItem', () {
    test('文件名清洗掉文件系统保留字符', () {
      const video = VideoItem(
        id: 'x',
        title: 'A/B:C*D?E"F<G>H|I\\J',
        author: 'author',
        hlsUrl: 'https://x/y.m3u8',
        publishedAt: '2026-03-14',
      );
      expect(video.downloadBaseName, '2026-03-14_A_B_C_D_E_F_G_H_I_J');
    });

    test('缺少日期时使用 unknown 占位', () {
      const video = VideoItem(
        id: 'x',
        title: 'T',
        author: 'a',
        hlsUrl: 'https://x/y.m3u8',
      );
      expect(video.downloadBaseName, 'unknown_T');
    });

    test('JSON 往返保持一致', () {
      const video = VideoItem(
        id: 'v1',
        title: 'Title',
        author: 'Author',
        hlsUrl: 'https://x/y.m3u8',
        duration: Duration(seconds: 634),
        publishedAt: '2026-03-14',
        tags: <String>['a', 'b'],
        views: 42,
      );
      final restored = VideoItem.fromJson(video.toJson());
      expect(restored.id, video.id);
      expect(restored.title, video.title);
      expect(restored.duration, video.duration);
      expect(restored.tags, video.tags);
      expect(restored.views, video.views);
    });
  });

  group('HlsCacheProxy & PreloadService 极速加载与预加载协同', () {
    test('isFullSpeedEnabled 开关切换与代理 URL 生成逻辑', () {
      final proxy = HlsCacheProxy.instance;
      const testVideo = VideoItem(
        id: 'https://example.com/view_video.php?viewkey=abc12345',
        title: '测试视频',
        author: '测试UP主',
        thumbnailUrl: '',
        durationStr: '10:00',
        hlsUrl: 'https://example.com/vod/index.m3u8',
      );

      // 当开关关闭时，直接原样透传
      proxy.isFullSpeedEnabled.value = false;
      final directUrl = proxy.getProxiedPlayUrl(
        testVideo.hlsUrl,
        item: testVideo,
      );
      expect(directUrl, testVideo.hlsUrl);

      // 当开关开启时
      proxy.isFullSpeedEnabled.value = true;
      expect(proxy.isFullSpeedEnabled.value, isTrue);
    });

    test('PreloadService getCachedHlsUrl 过滤本地 file 路径，优先取远端真实流地址', () {
      final preload = PreloadService.instance;
      const localItem = VideoItem(
        id: 'test_vid_001',
        title: '测试本地视频',
        author: '测试UP主',
        thumbnailUrl: '',
        durationStr: '05:00',
        hlsUrl: '/data/user/0/com.example/play.m3u8',
      );

      // 本地 file 路径不应被作为真实远端 HLS 流返回
      final cached = preload.getCachedHlsUrl(localItem);
      expect(cached, isNull);

      const remoteItem = VideoItem(
        id: 'test_vid_002',
        title: '测试远端视频',
        author: '测试UP主',
        thumbnailUrl: '',
        durationStr: '05:00',
        hlsUrl: 'https://cdn.example.com/hls/master.m3u8',
      );
      expect(
        preload.getCachedHlsUrl(remoteItem),
        'https://cdn.example.com/hls/master.m3u8',
      );
    });

    test('91 不复用没有新鲜度记录的持久化播放地址', () {
      Get.put<VideoSource>(Site91Source(baseUrl: 'https://91.example.test'));
      try {
        const item = VideoItem(
          id: 'https://91.example.test/video/view/cache-age-test',
          title: '91 cache age test',
          author: 'test',
          thumbnailUrl: '',
          durationStr: '05:00',
          hlsUrl:
              'https://cdn.example.com/hls/master.m3u8?token=possibly-expired',
          detailUrl: 'https://91.example.test/video/view/cache-age-test',
        );

        expect(PreloadService.instance.getCachedHlsUrl(item), isNull);
        expect(
          PreloadService.instance.isFreshPlaybackUrl(item, item.hlsUrl),
          isFalse,
        );
      } finally {
        Get.delete<VideoSource>(force: true);
      }
    });
  });
}
