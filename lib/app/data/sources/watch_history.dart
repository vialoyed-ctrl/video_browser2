/// 内容源「观看记录」相关能力的旁路扩展。
///
/// **为什么不直接加到 [VideoSource] 接口**：接口的实现方用的是 `implements`
/// 而不是 `extends`，加成员会**强制所有实现一起补齐**（包括不允许改动的 91 源）。
/// 与 `VideoSourceOwnership.ownsItem` 同一套路：扩展 + 类型判断。
///
/// ## 背景：官网的觀看紀錄是怎么来的
///
/// 实测官网 `app.js` 里**没有任何客户端上报** —— 没有 `sendBeacon`、没有裸
/// `fetch`、也没有播放进度监听（`timeupdate` / `currentTime` 全无命中），
/// 只有订阅、点赞、收藏、评论这几类表单提交。所以觀看紀錄是**服务端在收到
/// watch 页请求时**写入的。
///
/// 这就带来一个颠倒的结果：App 的详情有 15 分钟缓存，用户点开视频时往往直接
/// 命中缓存、一个请求都不发；而后台预取反而会把 watch 页拉一遍。于是
/// 「**真正点开的不记录，后台预取过的反而记录了**」。
///
/// 本扩展负责把这两条路径分开：
/// - [markWatched] —— 用户主动点开，强制带登录态请求一次，官网据此记录；
/// - [fetchDetailAnonymously] —— 后台预取，不带登录态，官网无从归属。
library;

import 'hanime1_source.dart';
import 'pornhub_source.dart';
import 'video_source.dart';

extension VideoSourceWatchHistory on VideoSource {
  /// 上报「用户主动打开了这个视频」—— **唯一**会在官网留下观看记录的入口。
  ///
  /// 只在用户主动点开时调用。未实现该能力的源直接 no-op。
  /// 调用方应当 fire-and-forget（`unawaited`），不要阻塞起播。
  Future<void> markWatched(String videoId) async {
    final self = this;
    if (self is Hanime1Source) {
      await self.markWatched(videoId);
    } else if (self is PornHubSource) {
      await self.markWatched(videoId);
    }
  }

  /// 后台预取专用的详情拉取：**不携带登录态**，不会在官网留下观看记录。
  ///
  /// 未实现该能力的源退化为普通 [VideoSource.fetchDetail]（行为不变）。
  Future<VideoDetail?> fetchDetailAnonymously(
    String videoId, {
    bool forceRefresh = false,
  }) {
    final self = this;
    if (self is Hanime1Source) {
      return self.fetchDetailAnonymous(videoId, forceRefresh: forceRefresh);
    }
    return fetchDetail(videoId, forceRefresh: forceRefresh);
  }
}
