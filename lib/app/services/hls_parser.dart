/// HLS (RFC 8216) 播放列表解析。
///
/// 原 Kotlin 项目把 m3u8 当成"一堆非 # 开头的行"直接下载
/// （见 `VideoDownloadManager.parseM3u8`），有三个问题：
///   1. 无法识别 master playlist，遇到多码率流会把变体地址当分片下载，必然失败；
///   2. 忽略 `#EXT-X-MAP`，fMP4 流缺少 init segment，合并后无法播放；
///   3. 忽略 `#EXT-X-KEY`，遇到 AES-128 加密流会静默产出损坏文件。
///
/// 本文件按标签语义解析，并对上述三种情况显式处理或明确报错。
library;

import 'dart:isolate';

/// master playlist 中的一路码率。
class HlsVariant {
  const HlsVariant({
    required this.uri,
    this.bandwidth,
    this.resolution,
    this.codecs,
  });

  final Uri uri;
  final int? bandwidth;
  final String? resolution;
  final String? codecs;

  /// 展示用标签，例如 `1920x1080` 或 `1500 kbps`。
  String get label {
    if (resolution != null && resolution!.isNotEmpty) return resolution!;
    if (bandwidth != null) return '${(bandwidth! / 1000).round()} kbps';
    return '自适应';
  }
}

/// 解析结果。master 与 media playlist 共用此结构，由 [isMaster] 区分。
class HlsPlaylist {
  const HlsPlaylist({
    required this.isMaster,
    this.variants = const <HlsVariant>[],
    this.segments = const <Uri>[],
    this.initSegment,
    this.durationSeconds = 0,
    this.encryptionMethod,
    this.encryptionKeyUri,
  });

  final bool isMaster;
  final List<HlsVariant> variants;

  /// media playlist 的分片地址（已解析为绝对地址）。
  final List<Uri> segments;

  /// `#EXT-X-MAP` 声明的初始化分片，fMP4 流必需。
  final Uri? initSegment;

  final double durationSeconds;

  /// 非 null 表示流被加密（如 `AES-128`）。
  final String? encryptionMethod;
  final Uri? encryptionKeyUri;

  bool get isEncrypted =>
      encryptionMethod != null && encryptionMethod != 'NONE';

  bool get isFragmentedMp4 => initSegment != null;

  /// 下载合并后应使用的扩展名。
  String get outputExtension => isFragmentedMp4 ? '.mp4' : '.ts';

  /// 分片总数（含 init segment）。
  int get totalParts => segments.length + (initSegment == null ? 0 : 1);
}

class HlsParseException implements Exception {
  HlsParseException(this.message);
  final String message;
  @override
  String toString() => 'HlsParseException: $message';
}

class HlsParser {
  const HlsParser._();

  static const String _extStreamInf = '#EXT-X-STREAM-INF';
  static const String _extMap = '#EXT-X-MAP';
  static const String _extKey = '#EXT-X-KEY';
  static const String _extInf = '#EXTINF';

  /// 复用分辨率匹配模式，避免每个画质候选项重复创建正则。
  static final _resolutionRe = RegExp(r'(\d+)\s*[xX]\s*(\d+)');

  /// 换行切分用的正则。
  ///
  /// 必须是常量：`RegExp` 的构造包含一次模式编译，写在函数体里就意味着
  /// **每次解析都重新编译一遍**。而 [parse] 在预加载与本地代理两条链路上
  /// 都是热路径（一次播放会调用几十次），这里省下的编译开销很可观。
  static final RegExp _newlineRe = RegExp(r'\r?\n');

  /// 解析 `KEY=VALUE,KEY="VALUE"` 属性列表用的正则。
  ///
  /// 同样必须提出来：[_parseAttributes] 对媒体清单里**每一条 `#EXT-X-KEY`**
  /// 都要调用一次，而 AES-128 加密流是**每个分片一条 KEY** —— 一部 2000 分片
  /// 的片子就是 2000 次调用，原本等于 2000 次正则编译。
  static final RegExp _attributeRe = RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)');

  /// 解析播放列表文本。[baseUri] 为 m3u8 自身的地址，用于解析相对路径。
  static HlsPlaylist parse(String content, Uri baseUri) {
    final lines = content
        .split(_newlineRe)
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      throw HlsParseException('播放列表为空');
    }
    if (!lines.first.startsWith('#EXTM3U')) {
      throw HlsParseException('不是合法的 m3u8：缺少 #EXTM3U 头');
    }

    final hasStreamInf = lines.any((l) => l.startsWith(_extStreamInf));
    return hasStreamInf
        ? _parseMaster(lines, baseUri)
        : _parseMedia(lines, baseUri);
  }

  static HlsPlaylist _parseMaster(List<String> lines, Uri baseUri) {
    final variants = <HlsVariant>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!line.startsWith(_extStreamInf)) continue;

      final attrs = _parseAttributes(line.substring(_extStreamInf.length));
      // 变体地址是紧随其后的第一条非注释行。
      Uri? uri;
      for (var j = i + 1; j < lines.length; j++) {
        if (!lines[j].startsWith('#')) {
          uri = _resolve(lines[j], baseUri);
          break;
        }
      }
      if (uri == null) continue;

      variants.add(
        HlsVariant(
          uri: uri,
          bandwidth: int.tryParse(attrs['BANDWIDTH'] ?? ''),
          resolution: attrs['RESOLUTION'],
          codecs: attrs['CODECS'],
        ),
      );
    }

    if (variants.isEmpty) {
      throw HlsParseException('master playlist 中没有解析到任何变体');
    }

    return HlsPlaylist(isMaster: true, variants: variants);
  }

  static HlsPlaylist _parseMedia(List<String> lines, Uri baseUri) {
    final segments = <Uri>[];
    Uri? initSegment;
    String? encryptionMethod;
    Uri? encryptionKeyUri;
    var duration = 0.0;

    for (final line in lines) {
      if (line.startsWith(_extMap)) {
        final attrs = _parseAttributes(line.substring(_extMap.length));
        final uri = attrs['URI'];
        if (uri != null) initSegment = _resolve(uri, baseUri);
        continue;
      }

      if (line.startsWith(_extKey)) {
        final attrs = _parseAttributes(line.substring(_extKey.length));
        encryptionMethod = attrs['METHOD'];
        final keyUri = attrs['URI'];
        if (keyUri != null) encryptionKeyUri = _resolve(keyUri, baseUri);
        continue;
      }

      if (line.startsWith(_extInf)) {
        // 形如 `#EXTINF:6.000,标题`：冒号是标签语法的一部分，必须先剥离，
        // 否则 double.tryParse 会失败并把时长静默记为 0。
        var raw = line.substring(_extInf.length);
        if (raw.startsWith(':')) raw = raw.substring(1);
        final value = raw.split(',').first.trim();
        duration += double.tryParse(value) ?? 0;
        continue;
      }

      if (line.startsWith('#')) continue;

      segments.add(_resolve(line, baseUri));
    }

    if (segments.isEmpty && initSegment == null) {
      throw HlsParseException('media playlist 中没有分片');
    }

    return HlsPlaylist(
      isMaster: false,
      segments: segments,
      initSegment: initSegment,
      durationSeconds: duration,
      encryptionMethod: encryptionMethod,
      encryptionKeyUri: encryptionKeyUri,
    );
  }

  /// 选出**画质最高**的一路。
  ///
  /// 排序键是 `(分辨率像素数, 码率)` 的字典序降序 —— **分辨率优先**。
  ///
  /// 为什么不能只看 `bandwidth`：`BANDWIDTH` 虽是 HLS 规范里的必填属性，
  /// 但实测有源站会省略它（或写成解析不出的形式）。那时所有变体都按 0 比较，
  /// `sort` 保持原有顺序，`first` 就成了「清单里的第一条」—— 而 master playlist
  /// 常见的排列是**从低到高**，于是静默播了最低画质，且没有任何日志能看出来。
  ///
  /// `RESOLUTION` 在解析变体时已经拿到（见 [HlsVariant.resolution] 的构造处），
  /// 这里直接把它用上。两者都缺失时退回「按码率排」，再都缺失才退回原顺序
  /// —— 即无分辨率信息时行为与旧实现完全一致。
  static HlsVariant pickBest(List<HlsVariant> variants) {
    if (variants.isEmpty) {
      throw HlsParseException('变体列表为空');
    }
    final sorted = List<HlsVariant>.from(variants)
      ..sort((a, b) {
        final byResolution = _resolutionPixels(b)
            .compareTo(_resolutionPixels(a));
        if (byResolution != 0) return byResolution;
        return (b.bandwidth ?? 0).compareTo(a.bandwidth ?? 0);
      });
    return sorted.first;
  }

  /// `1920x1080` → `2073600`。解析不出返回 0（视为「无分辨率信息」）。
  ///
  /// 用像素总数而非宽或高单独比较，这样 `1920x1080` 与 `1080x1920`（竖屏）
  /// 会被视为同等画质，而不是按宽度把竖屏误判成低画质。
  static int _resolutionPixels(HlsVariant v) {
    final raw = v.resolution;
    if (raw == null || raw.isEmpty) return 0;
    final m = _resolutionRe.firstMatch(raw);
    if (m == null) return 0;
    final w = int.tryParse(m.group(1)!);
    final h = int.tryParse(m.group(2)!);
    if (w == null || h == null) return 0;
    return w * h;
  }

  static HlsVariant? pickBestVariant(List<HlsVariant> variants) {
    if (variants.isEmpty) return null;
    return pickBest(variants);
  }

  /// 解析 `KEY=VALUE,KEY="VALUE"` 形式的属性列表。
  static Map<String, String> _parseAttributes(String raw) {
    final result = <String, String>{};
    for (final m in _attributeRe.allMatches(raw)) {
      final key = m.group(1);
      var value = m.group(2) ?? '';
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      if (key != null) result[key] = value;
    }
    return result;
  }

  static Uri _resolve(String ref, Uri baseUri) {
    final trimmed = ref.trim();
    final parsed = Uri.parse(trimmed);
    if (parsed.hasScheme) return parsed;
    return baseUri.resolve(trimmed);
  }

  /// 在**后台 isolate** 里解析 m3u8（[parse] 的异步版本）。
  ///
  /// 为什么需要它：解析是纯 CPU 的字符串 + 正则工作，而 Dart 默认只在主
  /// isolate 上跑。实测一部 2000 分片、每片一条 `#EXT-X-KEY` 的加密清单，
  /// 单次解析在主 isolate 上要几十毫秒；而预加载队列一次要解析上百个清单
  /// （真机实测启动 20 秒内 44 次预加载 × 每个 2 次解析），叠加起来直接把
  /// UI 线程占满。
  ///
  /// 真机 ANR trace 的主线程栈正是：
  /// ```
  /// HlsParser.parse → _StringBase.split → _AllMatchesIterator.moveNext
  ///                 → _RegExp._ExecuteMatch
  /// ```
  ///
  /// 用 `Isolate.run` 而非 `compute`：后者要求顶层函数 + 单参数，前者直接
  /// 收闭包；且返回值经 `Isolate.exit` **转移所有权**，无需序列化拷贝。
  static Future<HlsPlaylist> parseInBackground(String content, Uri baseUri) {
    return Isolate.run(() => parse(content, baseUri));
  }
}
