/// 纯 Dart 逻辑验证脚本（不依赖 flutter_tester）。
///
/// 用途：本机 `flutter test` 因 flutter_tester 的 WebSocket 握手失败无法运行，
/// 这里用普通 Dart VM 直接验证不依赖 Flutter 的核心逻辑。
///
/// 运行：
///   dart run tool/verify_logic.dart
///
/// `test/core_logic_test.dart` 仍是标准的 `flutter test` 用例，
/// 在能正常启动 flutter_tester 的机器上应优先使用它。
// ignore_for_file: avoid_print
library;

import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/hls_parser.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool Function() body) {
  try {
    if (body()) {
      _passed++;
      print('  PASS  $name');
    } else {
      _failed++;
      print('  FAIL  $name');
    }
  } catch (e) {
    _failed++;
    print('  FAIL  $name  -> 抛出异常: $e');
  }
}

bool throwsParse(String content) {
  try {
    HlsParser.parse(content, Uri.parse('https://x/y.m3u8'));
    return false;
  } on HlsParseException {
    return true;
  }
}

Future<void> main() async {
  print('== HlsParser: media playlist ==');
  const media = '''
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-MAP:URI="init.mp4"
#EXTINF:6.0,
seg0.m4s
#EXTINF:6.0,
seg1.m4s
#EXT-X-ENDLIST
''';
  final parsed = HlsParser.parse(
    media,
    Uri.parse('https://cdn.example.com/vod/720p/index.m3u8'),
  );
  check('识别为 media playlist', () => !parsed.isMaster);
  check('识别 fMP4 容器', () => parsed.isFragmentedMp4);
  check('输出扩展名为 .mp4', () => parsed.outputExtension == '.mp4');
  check(
    'init segment 解析为绝对地址',
    () =>
        parsed.initSegment.toString() ==
        'https://cdn.example.com/vod/720p/init.mp4',
  );
  check('分片数量为 2', () => parsed.segments.length == 2);
  check(
    '分片相对路径解析正确',
    () =>
        parsed.segments.first.toString() ==
        'https://cdn.example.com/vod/720p/seg0.m4s',
  );
  check('累计时长为 12 秒', () => (parsed.durationSeconds - 12).abs() < 0.001);
  check('总分片数含 init 为 3', () => parsed.totalParts == 3);

  const tsPlaylist = '''
#EXTM3U
#EXTINF:6.0,
a.ts
#EXTINF:6.0,
b.ts
''';
  final ts = HlsParser.parse(
    tsPlaylist,
    Uri.parse('https://cdn.example.com/hls/index.m3u8'),
  );
  check('TS 流输出扩展名为 .ts', () => ts.outputExtension == '.ts');
  check('TS 流非 fMP4', () => !ts.isFragmentedMp4);

  const encrypted = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="key.bin"
#EXTINF:6.0,
a.ts
''';
  final enc = HlsParser.parse(
    encrypted,
    Uri.parse('https://cdn.example.com/hls/index.m3u8'),
  );
  check('识别 AES-128 加密', () => enc.isEncrypted);
  check('加密方法解析正确', () => enc.encryptionMethod == 'AES-128');
  check(
    '密钥地址解析正确',
    () =>
        enc.encryptionKeyUri.toString() ==
        'https://cdn.example.com/hls/key.bin',
  );

  check('空内容抛异常', () => throwsParse(''));
  check('非 m3u8 内容抛异常', () => throwsParse('<html></html>'));

  print('== HlsParser: master playlist ==');
  const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
720/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080
1080/index.m3u8
''';
  final m = HlsParser.parse(
    master,
    Uri.parse('https://cdn.example.com/vod/master.m3u8'),
  );
  check('识别为 master playlist', () => m.isMaster);
  check('解析出 3 路变体', () => m.variants.length == 3);
  check(
    '变体地址解析正确',
    () =>
        m.variants.first.uri.toString() ==
        'https://cdn.example.com/vod/360/index.m3u8',
  );
  final best = HlsParser.pickBest(m.variants);
  check('pickBest 选中最高码率', () => best.bandwidth == 6000000);
  check('pickBest 标签为分辨率', () => best.label == '1920x1080');

  print('== VideoItem ==');
  const messy = VideoItem(
    id: 'x',
    title: 'A/B:C*D?E"F<G>H|I\\J',
    author: 'author',
    hlsUrl: 'https://x/y.m3u8',
    publishedAt: '2026-03-14',
  );
  check(
    '文件名清洗保留字符',
    () => messy.downloadBaseName == '2026-03-14_A_B_C_D_E_F_G_H_I_J',
  );
  const noDate = VideoItem(
    id: 'x',
    title: 'T',
    author: 'a',
    hlsUrl: 'https://x/y.m3u8',
  );
  check('缺日期时用 unknown 占位', () => noDate.downloadBaseName == 'unknown_T');
  const roundTrip = VideoItem(
    id: 'v1',
    title: 'Title',
    author: 'Author',
    hlsUrl: 'https://x/y.m3u8',
    duration: Duration(seconds: 634),
    publishedAt: '2026-03-14',
    tags: <String>['a', 'b'],
    views: 42,
  );
  final restored = VideoItem.fromJson(roundTrip.toJson());
  check(
    'JSON 往返一致',
    () =>
        restored.id == roundTrip.id &&
        restored.title == roundTrip.title &&
        restored.duration == roundTrip.duration &&
        restored.tags.length == roundTrip.tags.length &&
        restored.views == roundTrip.views,
  );

  print('');
  print('通过 $_passed 项，失败 $_failed 项');
  if (_failed > 0) {
    throw StateError('存在失败项');
  }
}
