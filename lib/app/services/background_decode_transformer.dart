/// HTTP 响应体的**后台解码** Transformer。
///
/// 作用：把「把响应字节流解码成 String」这一步从主 isolate 挪到后台 isolate。
///
/// ---------------------------------------------------------------------------
/// 为什么必须自己写一个
/// ---------------------------------------------------------------------------
///
/// dio 默认的 `FusedTransformer`（以及它那个看起来更高级的子类
/// `BackgroundTransformer`）对**非 JSON** 响应一律执行：
///
/// ```dart
/// return utf8.decode(responseBytes);   // 主 isolate，同步
/// ```
///
/// `BackgroundTransformer` 只在 **JSON 且超过阈值** 时才用 `compute()`，
/// 而本 App 抓的**全是 HTML 页面**（91 首页、hanime1 详情页动辄几百 KB ~ 2 MB），
/// 于是解码开销 100% 压在 UI 线程上。
///
/// 真机 ANR 取证（`.perf/anr_new.txt`，2026-09-29 02:47:25，包 v2001）——
/// 主线程 `state=R`（正在跑 CPU），栈顶逐帧：
///
/// ```
/// _Utf8Decoder.decodeGeneral            dart:convert/utf.dart:643
/// _Utf8Decoder.convertSingle            dart:convert/convert_patch.dart:1864
/// Utf8Decoder.convert                   dart:convert/utf.dart:348
/// Utf8Codec.decode                      dart:convert/utf.dart:62
/// FusedTransformer.transformResponse    package:dio/src/transformers/fused_transformer.dart:105
/// ```
///
/// 即：主线程当时**正在同步解码一个 HTTP 响应体**。启动 20 秒内会发起几十次
/// 页面请求（首页 + 各频道 + 逐条视频详情预加载），单次解码几十毫秒，
/// 叠加起来轻松突破 ANR 的 5 秒门槛。
///
/// ---------------------------------------------------------------------------
/// 行为完全等价
/// ---------------------------------------------------------------------------
///
/// 输出的 String 与 dio 默认实现逐字节一致，只是换了个线程干活。
/// 判断 JSON 的依据同样取自 `Content-Type`（与 dio 默认一致），
/// **不看 `options.responseType`** —— 否则 `get<String>` 这种写法会被误判。
library;

import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// 低于这个字节数就直接在主 isolate 解码。
///
/// isolate 冷启动约 1~3ms，小响应（几 KB 的接口/短页面）走后台反而更慢。
/// 32KB 是分界点：再小的解码耗时不到 1ms，再大的后台收益明显。
const int kBackgroundDecodeThreshold = 32 * 1024;

class BackgroundDecodeTransformer extends Transformer {
  // 注意：这里**不能**写成 const 构造函数 —— 父类 `Transformer` 的构造函数
  // 不是 const，写了会报 `const_constructor_with_non_const_super`。
  BackgroundDecodeTransformer({
    this.backgroundThreshold = kBackgroundDecodeThreshold,
  });

  /// 超过该字节数的响应体才丢到后台 isolate 解码。
  final int backgroundThreshold;

  @override
  Future<String> transformRequest(RequestOptions options) async {
    final data = options.data;
    if (data == null) return '';
    if (data is String) return data;
    if (data is Map || data is List) return jsonEncode(data);
    return data.toString();
  }

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody response,
  ) async {
    final bytes = await _consolidate(response.stream);
    if (bytes.isEmpty) return '';

    // 与 dio 默认实现同一判据：只看 Content-Type。
    //
    // 注意 `ResponseBody.headers` 的类型是 `Map<String, List<String>>`，
    // **不是** `Headers` 对象（没有 `.value()` 方法），而且 key 的大小写不保证，
    // 所以要自己遍历比对。
    var contentType = '';
    for (final e in response.headers.entries) {
      if (e.key.toLowerCase() == Headers.contentTypeHeader) {
        contentType = e.value.join(';');
        break;
      }
    }
    final isJson = contentType.contains('json');

    // 大响应丢后台 —— 这一步是本次修复的全部意义所在。
    // 不能声明成 final：下面 try 与 catch 两条路径都要赋值。
    String text;
    if (bytes.length >= backgroundThreshold) {
      try {
        // 后台 isolate 必须有**硬上限**：实测在真机上出现过 isolate 迟迟不返回，
        // 导致该 HTTP 请求永久 pending（dio 的 receiveTimeout 只管 socket 读，
        // 管不到解码这一步）—— 表现就是播放页一直停在「正在解析播放地址…」。
        // 超时即退回主 isolate 解码：最差只是慢几十毫秒，绝不会把请求挂死。
        text = await Isolate.run(() => utf8.decode(bytes)).timeout(
          const Duration(seconds: 8),
          onTimeout: () => utf8.decode(bytes),
        );
      } catch (_) {
        // isolate 起不来（内存吃紧等）不能让整个请求失败 ——
        // 退回主 isolate 解码，最差也只是慢，而不是拿不到数据。
        // 注意：真正的解码错误（FormatException）两种路径都会抛，行为不变。
        text = utf8.decode(bytes);
      }
    } else {
      text = utf8.decode(bytes);
    }

    if (!isJson) return text;

    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    return jsonDecode(trimmed);
  }

  /// 把响应流收成一个 [Uint8List]。
  ///
  /// 刻意不复用 dio 内部的 `consolidateBytes` —— 那是 `src/` 下的工具函数，
  /// 不同小版本之间导出的位置变过，自己写十行更稳。
  ///
  /// **关键**：dio 的 `receiveTimeout` 只覆盖「等响应头」那一段
  /// （见 `dio/lib/src/adapters/io_adapter.dart`：它给 `request.close()` 加超时），
  /// **不覆盖读 body**。因此若代理 / CDN 在传输途中停住（真机实测出现过），
  /// 这里会 await 到永远 —— 表现就是请求永久 pending、播放页一直停在
  /// 「正在解析播放地址…」，且**任何超时都不会触发**（主 isolate 也不忙）。
  /// 这里给流加一个空闲超时：超过 [_bodyIdleTimeout] 没有新数据即判失败，
  /// 让上层能报错 / 重试，而不是无限转圈。
  static const Duration _bodyIdleTimeout = Duration(seconds: 20);

  static Future<Uint8List> _consolidate(Stream<Uint8List> stream) async {
    final chunks = <Uint8List>[];
    var total = 0;
    await for (final chunk in stream.timeout(_bodyIdleTimeout)) {
      if (chunk.isEmpty) continue;
      chunks.add(chunk);
      total += chunk.length;
    }
    if (chunks.isEmpty) return Uint8List(0);
    if (chunks.length == 1) return chunks.first;

    final out = Uint8List(total);
    var offset = 0;
    for (final c in chunks) {
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }
}
