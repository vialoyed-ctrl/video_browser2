/// 视频详情与播放视图。
/// 仿哔哩哔哩移动端 (PiliPlus) 布局风格：
/// 1. 顶部手势控制播放器（无多余内置控制层、单进度条、左右垂直滑动手势、横向进度预演、双击快进快退、长按2X倍速）；
/// 2. 中部作品元数据（标题、UP主信息、播放量、作品发布时间、下载操作）；
/// 3. 下部相关推荐视频列表（点击原地换片切换播放）。
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/app_theme.dart';

import 'package:flutter/services.dart';

import '../../widgets/app_toast.dart';

import 'package:get/get.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_logger.dart';
import '../../core/responsive_utils.dart';
import '../../data/models/hanime1_models.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/hanime1_source.dart';
import '../../data/sources/video_source.dart';
import '../hanime1/widgets/hanime1_card_h.dart';
import '../pornhub/views/pornhub_video_info_panel.dart';
import '../../routes/app_navigator.dart';
import '../../services/download_service.dart';
import '../../services/user_service.dart';
import '../../widgets/bili_video_card.dart';
import 'hanime1_comments.dart';
import 'hanime1_video_info.dart';
import 'player_controller.dart';
import 'widgets/frame_scrub_bar.dart';
import 'widgets/player_hud.dart';
import 'widgets/seek_indicators.dart';

class PlayerView extends StatefulWidget {
  const PlayerView({super.key, this.videoItem});

  final VideoItem? videoItem;

  @override
  State<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends State<PlayerView> {
  late final String _tag;
  late final PlayerController controller;

  /// Hanime1 播放页的 Tab 下标（0 = 相關影片，1 = 評論）。
  ///
  /// 对应官网 `#tablinks-wrapper` 里的两个 `button.tablinks`，
  /// 默认打开的是「相關影片」（`button#defaultOpen`）。
  int _hanime1Tab = 0;

  /// 上面那个下标是跟着视频走的；换片时用它判断是否需要复位。
  String? _tabVideoId;

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  @override
  void initState() {
    super.initState();
    _tag =
        'player_${DateTime.now().microsecondsSinceEpoch}_${UniqueKey().hashCode}';
    final targetVideo =
        widget.videoItem ??
        (Get.arguments is VideoItem ? Get.arguments as VideoItem : null);
    AppLogger.i(
      'PlayerView',
      '🎬 初始化 PlayerView (tag: $_tag), 视频: ${targetVideo?.title}',
    );
    controller = Get.put(
      PlayerController(initialVideo: targetVideo),
      tag: _tag,
    );
  }

  @override
  void dispose() {
    AppLogger.i('PlayerView', '👋 销毁 PlayerView (tag: $_tag)');
    Get.delete<PlayerController>(tag: _tag);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWide = ResponsiveLayout.isWideScreen(context);

    return Obx(() {
      final isFull = controller.isFullscreen.value;

      return PopScope(
        canPop: !isFull,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) {
            controller.stop();
            return;
          }
          if (controller.isFullscreen.value) {
            await controller.exitFullscreen();
          }
        },
        child: Scaffold(
          backgroundColor: isFull
              ? Colors.black
              : theme.scaffoldBackgroundColor,
          body: isFull
              ? SizedBox.expand(child: _buildPlayerWidget(context))
              : (isWide
                    ? SafeArea(
                        top: true,
                        bottom: false,
                        child: Row(
                          children: [
                            // 平板横屏 / 宽屏大屏：左侧主视频播放器（占比 64% 沉浸窗口）
                            Expanded(
                              flex: 64,
                              child: ColoredBox(
                                color: Colors.black,
                                child: Center(
                                  child: _buildPlayerWidget(context),
                                ),
                              ),
                            ),
                            const VerticalDivider(thickness: 0.8, width: 0.8),
                            // 右侧独立滚动的作品信息与相关推荐（占比 36%）
                            Expanded(
                              flex: 36,
                              child: _buildPlayerBody(context),
                            ),
                          ],
                        ),
                      )
                    : SafeArea(
                        top: true,
                        child: Column(
                          children: [
                            // 手机竖屏 / 平板竖屏：顶部播放器（大屏限高保护）
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 460),
                              child: _buildPlayerWidget(context),
                            ),
                            // 下方视频信息与相关推荐列表
                            Expanded(child: _buildPlayerBody(context)),
                          ],
                        ),
                      )),
        ),
      );
    });
  }

  // ------------------------------------------------------------- 播放器模块
  Widget _buildPlayerWidget(BuildContext context) {
    final isFull = controller.isFullscreen.value;
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final boxWidth = constraints.maxWidth;
        final boxHeight = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            // 1. 媒体底层：支持切换 BoxFit.contain（适应原比例）与 BoxFit.cover（彻底铺满屏幕无黑边）
            Obx(() {
              // Read an Rx value before the null check. The player controller
              // is intentionally absent on the first frame; short-circuiting
              // before reading any Rx makes GetX report an invalid empty Obx.
              final isInitialized = controller.isInitialized.value;
              final vp = controller.videoPlayerController;
              final isReady =
                  vp != null && isInitialized && vp.value.isInitialized;

              if (isReady) {
                final fit = controller.videoFit.value;
                final size = vp.value.size;
                final w = size.width > 0 ? size.width : 16.0;
                final h = size.height > 0 ? size.height : 9.0;
                final player = VideoPlayer(
                  vp,
                  key: ValueKey('vp_${vp.hashCode}_${vp.dataSource}'),
                );

                return Container(
                  color: Colors.black,
                  child: SizedBox.expand(
                    child: FittedBox(
                      fit: fit,
                      clipBehavior: Clip.hardEdge,
                      child: RotatedBox(
                        quarterTurns: controller.videoRotation.value,
                        child: SizedBox(
                          width: w,
                          height: h,
                          child: ColoredBox(color: Colors.black, child: player),
                        ),
                      ),
                    ),
                  ),
                );
              }
              return Container(color: Colors.black);
            }),

            // 1.1 封面占位无缝过渡层：在视频第一帧出画前始终显示高清封面，杜绝黑屏死角感知与异常灰屏
            Obx(() {
              final isInitialized = controller.isInitialized.value;
              final vp = controller.videoPlayerController;
              final hasFrame =
                  vp != null &&
                  isInitialized &&
                  vp.value.isInitialized &&
                  vp.value.size.width > 0 &&
                  controller.position.value > Duration.zero;
              final coverUrl = controller.video.value?.thumbnailUrl;
              return IgnorePointer(
                child: AnimatedOpacity(
                  opacity: hasFrame ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  child: coverUrl != null && coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: controller.videoFit.value,
                          memCacheWidth: 600,
                          httpHeaders: const {
                            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
                            'Referer': 'https://91porny.com/',
                          },
                          placeholder: (_, _) => Container(color: Colors.black),
                          errorWidget: (_, _, _) =>
                              Container(color: Colors.black),
                        )
                      : Container(color: Colors.black),
                ),
              );
            }),

            // Keep the existing 91 loading feedback. Hanime1 displays its cover
            // while the stream resolves, without a blocking spinner overlay.
            Obx(() {
              final isInitialized = controller.isInitialized.value;
              final vp = controller.videoPlayerController;
              final hasFrame =
                  vp != null &&
                  isInitialized &&
                  vp.value.isInitialized &&
                  vp.value.size.width > 0 &&
                  controller.position.value > Duration.zero;
              if (_isHanime1Video(controller.video.value) ||
                  hasFrame ||
                  controller.error.value != null ||
                  controller.resolving.value) {
                return const SizedBox.shrink();
              }
              return const Center(
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                ),
              );
            }),

            // 2. 多手势触控交互层（左亮度/右音量/横向Seek/长按2X/双击快进退）
            _PlayerGestureZone(
              controller: controller,
              boxWidth: boxWidth,
              boxHeight: boxHeight,
            ),

            // 3. 快退/快进渐变浮层（连击递增秒数与即时反馈）
            Obx(() {
              if (controller.showBackwardSeek.value) {
                return Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: boxWidth * 0.45,
                  child: BackwardSeekIndicator(
                    seconds: controller.backwardSeekSeconds.value,
                    onSubmitted: controller.commitBackwardSeek,
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
            Obx(() {
              if (controller.showForwardSeek.value) {
                return Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: boxWidth * 0.45,
                  child: ForwardSeekIndicator(
                    seconds: controller.forwardSeekSeconds.value,
                    onSubmitted: controller.commitForwardSeek,
                  ),
                );
              }
              return const SizedBox.shrink();
            }),
            // 4. 收起控制栏时的底边极细常驻迷你进度条（对齐图3）
            _buildMiniProgressBar(context),

            // 5. 滑动 Seek 时的极简浮动时间胶囊（无冗余黑卡方框、无多余进度条）
            _buildSeekingTimePill(context),

            // 亮度 HUD（对齐用户截图：居中黑透胶囊 + 左边缘细条）
            Obx(() {
              if (controller.showBrightnessHud.value) {
                return BrightnessHud(brightness: controller.brightness.value);
              }
              return const SizedBox.shrink();
            }),

            // 音量 HUD（对齐用户截图：居中黑透胶囊 + 左边缘细条）
            Obx(() {
              if (controller.showVolumeHud.value) {
                return VolumeHud(volume: controller.volume.value);
              }
              return const SizedBox.shrink();
            }),

            Obx(() {
              if (controller.isSpeeding.value) {
                return const SpeedingHud();
              }
              return const SizedBox.shrink();
            }),

            Obx(() {
              if (_isHanime1Video(controller.video.value) ||
                  !controller.resolving.value) {
                return const SizedBox.shrink();
              }
              return Container(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(color: Colors.white),
                      const SizedBox(height: 12),
                      Text(
                        controller.resolveStatus.value,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),

            // 5. 播放错误横幅
            Obx(() {
              final err = controller.error.value;
              if (err != null) {
                return Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: context.cError,
                          size: 36,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          err,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 14),
                        FilledButton.tonal(
                          onPressed: controller.reload,
                          child: const Text('重试加载'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              return const SizedBox.shrink();
            }),

            // 7. 浮层控制栏（自动淡入淡出；滑动 Seek、调亮度/音量 HUD 期间绝不显示控制栏，保持纯净画面）
            Obx(() {
              final isSeeking = controller.isSeeking.value;
              final isHudActive =
                  isSeeking ||
                  controller.showBrightnessHud.value ||
                  controller.showVolumeHud.value;
              final visible = controller.showControls.value && !isHudActive;
              return AnimatedOpacity(
                opacity: visible ? 1.0 : 0.0,
                duration: isHudActive
                    ? Duration.zero
                    : const Duration(milliseconds: 250),
                child: IgnorePointer(
                  ignoring: !visible,
                  child: Stack(
                    children: [_buildTopBar(context), _buildBottomBar(context)],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );

    if (isFull) {
      return ColoredBox(
        color: Colors.black,
        child: SizedBox.expand(child: content),
      );
    }

    return ColoredBox(
      color: Colors.black,
      child: AspectRatio(aspectRatio: 16 / 9, child: content),
    );
  }

  // 顶部控制条（返回按钮 + 视频标题 + 刷新）
  Widget _buildTopBar(BuildContext context) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      // Positioned 必须是 Stack 的直接子节点，所以「拖动时隐藏」只能放在它**内部**：
      // 在外面再包一层 Visibility，会让 Positioned 拿到 BoxParentData 却按
      // StackParentData 强转，直接抛类型错误并陷入无限重建（真机表现为点开视频就 ANR）。
      child: Obx(
        () => Visibility(
          visible: !controller.isScrubbing.value,
          maintainSize: true,
          maintainAnimation: true,
          maintainState: true,
          child: Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xCC000000), Colors.transparent],
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(
                    Icons.arrow_back_ios_new,
                    color: AppTheme.playerAccent,
                    size: 20,
                  ),
                  onPressed: () {
                    if (controller.isFullscreen.value) {
                      controller.exitFullscreen();
                    } else {
                      controller.stop();
                      Get.back<void>();
                    }
                  },
                ),
                Expanded(
                  child: Obx(
                    () => Text(
                      controller.video.value?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.playerAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
                // The floating accessibility ball can cover the fullscreen action
                // in the lower control row on some phones. Keep a second entry in
                // the top bar where it remains reachable in portrait mode.
                IconButton(
                  tooltip: controller.isFullscreen.value ? '退出全屏' : '全屏',
                  icon: Icon(
                    controller.isFullscreen.value
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                    color: AppTheme.playerAccent,
                    size: 22,
                  ),
                  onPressed: controller.toggleFullscreen,
                ),
                IconButton(
                  tooltip: '重新加载',
                  icon: const Icon(
                    Icons.refresh,
                    color: AppTheme.playerAccent,
                    size: 22,
                  ),
                  onPressed: controller.reload,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 底部控制栏（对齐图2：上方贯穿浅蓝进度条，下方左侧大播放键+双行纵向堆叠时间，右侧功能区）
  Widget _buildBottomBar(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.only(bottom: 4),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xE6000000), Color(0x99000000), Colors.transparent],
            stops: [0.0, 0.7, 1.0],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. 上层：全宽水平进度条（对齐图2：独立位于按钮上方，浅蓝紫游标与轨道）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Obx(() {
                final hasDuration = controller.duration.value > Duration.zero;
                final totalDur = hasDuration
                    ? controller.duration.value
                    : const Duration(seconds: 1);
                // 拖动进度条时位置由手指决定，优先读 scrubPosition。
                final currentPos = controller.isScrubbing.value
                    ? controller.scrubPosition.value
                    : controller.isSeeking.value
                    ? controller.seekPreviewPosition.value
                    : (hasDuration ? controller.position.value : Duration.zero);
                final currentBuffered = hasDuration
                    ? controller.buffered.value
                    : Duration.zero;

                return FrameScrubBar(
                  progress: currentPos,
                  buffered: currentBuffered,
                  total: totalDur,
                  // 帧率来自当前选中视频轨；拿不到时气泡只显示时间。
                  frameRate: controller.scrubFrameRate,
                  progressBarColor: AppTheme.playerAccent,
                  baseBarColor: Colors.white24,
                  bufferedBarColor: AppTheme.playerBuffer,
                  thumbColor: AppTheme.playerAccent,
                  thumbGlowColor: AppTheme.playerGlow,
                  thumbRadius: controller.isSeeking.value ? 7.5 : 6.0,
                  thumbGlowRadius: controller.isSeeking.value ? 16.0 : 12.0,
                  barHeight: 3.0,
                  // 拖动过程中画面实时跟随手指（逐帧），松手落到精确位置。
                  onScrubStart: controller.beginScrub,
                  onScrubUpdate: controller.updateScrub,
                  onScrubEnd: (at) => controller.endScrub(),
                );
              }),
            ),
            // 2. 下层：控制按钮行（左侧播放键+双行堆叠时间，右侧倍速、画幅、旋转、全屏）
            //
            // 拖动进度条期间整行隐藏（maintainSize 保留占位以稳定几何）：此刻用户要的是
            // 「只有一条进度条 + 缓存条」，播放键、倍速、画幅这些都属于「其他的」。
            Visibility(
              visible: !controller.isScrubbing.value,
              maintainSize: true,
              maintainAnimation: true,
              maintainState: true,
              child: Padding(
                padding: const EdgeInsets.only(left: 4, right: 8, bottom: 2),
                child: Row(
                  children: [
                    // 播放/暂停
                    Obx(
                      () => IconButton(
                        icon: Icon(
                          controller.playing.value
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: AppTheme.playerAccent,
                          size: 30,
                        ),
                        onPressed: controller.togglePlay,
                      ),
                    ),
                    // 纵向双行堆叠时长：上行当前时间，下行总时长（对齐图2）
                    Obx(() {
                      final scrubbing = controller.isScrubbing.value;
                      final currentPos = scrubbing
                          ? controller.scrubPosition.value
                          : controller.isSeeking.value
                          ? controller.seekPreviewPosition.value
                          : controller.position.value;
                      // 逐帧拖动时秒级读数不够用（24fps 下相邻两帧只差 42ms），
                      // 拖动中改用毫秒级显示。
                      final pos = scrubbing
                          ? formatPreciseDuration(currentPos)
                          : _formatDuration(currentPos);
                      final dur = _formatDuration(controller.duration.value);
                      return Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              pos,
                              style: TextStyle(
                                color:
                                    (controller.isSeeking.value ||
                                        controller.isScrubbing.value)
                                    ? AppTheme.playerAccent
                                    : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                height: 1.15,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              dur,
                              style: const TextStyle(
                                color: Colors.white60,
                                fontWeight: FontWeight.normal,
                                fontSize: 10.5,
                                height: 1.15,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Spacer(),
                    // 倍速切换（文字显示为 1.0X）
                    PopupMenuButton<double>(
                      initialValue: controller.speed.value,
                      tooltip: '倍速',
                      onSelected: controller.setSpeed,
                      itemBuilder: (context) => [
                        for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                          PopupMenuItem(value: s, child: Text('${s}X')),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Obx(
                          () => Text(
                            '${controller.speed.value}X',
                            style: const TextStyle(
                              color: AppTheme.playerAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 画幅比例
                    IconButton(
                      icon: Obx(
                        () => Icon(
                          controller.videoFit.value == BoxFit.cover
                              ? Icons.fit_screen
                              : Icons.fullscreen,
                          color: AppTheme.playerAccent,
                          size: 20,
                        ),
                      ),
                      tooltip: '画幅比例',
                      onPressed: controller.toggleVideoFit,
                    ),
                    // 旋转屏幕
                    IconButton(
                      icon: const Icon(
                        Icons.screen_rotation,
                        color: AppTheme.playerAccent,
                        size: 20,
                      ),
                      tooltip: '旋转',
                      onPressed: controller.toggleRotation,
                    ),
                    // 全屏按钮
                    IconButton(
                      icon: Obx(
                        () => Icon(
                          controller.isFullscreen.value
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          color: AppTheme.playerAccent,
                          size: 26,
                        ),
                      ),
                      onPressed: controller.toggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 收起控制栏时的底边极细常驻迷你进度条；**屏幕横滑 Seek 期间同样显示**，
  // 因为「画面跟着手指走」的时候必须有一条进度参照，否则用户不知道自己在哪。
  // 拖动控制栏里那条进度条时则让位给控制栏自身的那条，避免两条重叠。
  Widget _buildMiniProgressBar(BuildContext context) {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Obx(() {
          final isSeeking = controller.isSeeking.value;
          final isScrubbing = controller.isScrubbing.value;
          final totalMs = controller.duration.value.inMilliseconds;
          // 拖动期间 controller 已把 position 同步为手指位置，统一读它即可。
          final currentMs = controller.position.value.inMilliseconds;
          final bufferedMs = controller.buffered.value.inMilliseconds;

          final playFraction = totalMs > 0
              ? (currentMs / totalMs).clamp(0.0, 1.0)
              : 0.0;
          final bufferFraction = totalMs > 0
              ? (bufferedMs / totalMs).clamp(0.0, 1.0)
              : 0.0;

          final isControlsVisible =
              controller.showControls.value && !isSeeking && !isScrubbing;
          // 拖动控制栏那条进度条时由它自己承担显示；亮度/音量 HUD 期间保持纯净。
          final isHudActive =
              isScrubbing ||
              controller.showBrightnessHud.value ||
              controller.showVolumeHud.value;
          final shouldShow = !isControlsVisible && !isHudActive && totalMs > 0;

          // 拖动中加粗提亮：2.5px 的暗条在视频画面上几乎看不见，
          // 而「拖动时缓存条要看得见」正是这次要解决的诉求。
          final emphasized = isSeeking;

          return AnimatedOpacity(
            opacity: shouldShow ? 1.0 : 0.0,
            // 拖动期间即时显隐：淡入淡出会让进度条慢半拍，跟不上手指。
            duration: (isHudActive || emphasized)
                ? Duration.zero
                : const Duration(milliseconds: 200),
            child: SizedBox(
              height: emphasized ? 4.0 : 2.5,
              child: Stack(
                children: [
                  // 底色背景条
                  Container(
                    color: emphasized
                        ? const Color(0x8C000000)
                        : const Color(0x33000000),
                  ),
                  // 缓冲条（缓存进度）—— 拖动时用更高的对比度，明确「已缓存到哪」
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: bufferFraction,
                    child: Container(
                      color: emphasized
                          ? const Color(0x8CFFFFFF)
                          : Colors.white24,
                    ),
                  ),
                  // 播放进度条（拖动时固定用蓝色，与参考效果一致）
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: playFraction,
                    child: Container(
                      color: emphasized
                          ? AppTheme.playerAccent
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  // 滑动 Seek 时的极简浮动时间胶囊（对齐用户图示：顶部居中、半透明黑底、纯粹仅显示 02:17 / 17:53）
  Widget _buildSeekingTimePill(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: Obx(() {
          if (!controller.isSeeking.value) return const SizedBox.shrink();
          final target = controller.seekPreviewPosition.value;
          final total = controller.duration.value;

          return Align(
            alignment: const Alignment(0.0, -0.65),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xB3000000), // 半透明黑底
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: _formatDuration(target),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const TextSpan(
                      text: ' / ',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                      ),
                    ),
                    TextSpan(
                      text: _formatDuration(total),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                        fontWeight: FontWeight.normal,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ------------------------------------------------------------- 视频元数据与UP主信息
  Widget _buildVideoInfo(BuildContext context) {
    final theme = Theme.of(context);

    return Obx(() {
      final v = controller.video.value;
      if (v == null) return const SizedBox.shrink();

      // Hanime1 的作品信息区与 91 差异极大（点赞率+踩、儲存/報錯/更多菜单、
      // 带计数的标签、上传者、所属清单），走专属实现。
      //
      // 判据必须是 [_isHanime1Video]（只看 `detailUrl`，**不依赖详情是否已解析**）。
      // 原先用的是 `extra != null && extra.hasAny`，于是首次打开一个 hanime1
      // 视频时详情还没回来，这里会先渲染 **91 的版式**，等详情到达后再整体跳变成
      // hanime1 版式 —— 用户看到的就是「打开播放器转一圈才出现 hanime1 的页面」。
      //
      // [Hanime1VideoInfo.extra] 现在允许为 null：版式先立起来，字段随后补齐。
      if (_isHanime1Video(v)) {
        return Hanime1VideoInfo(
          video: v,
          extra: _hanime1ExtraFor(v),
          onDownload: () => _enqueueDownload(video: v),
          onSelectPlaylistItem: controller.switchVideo,
        );
      }

      if (SourceRegistry.isSite91MdVideo(v)) {
        return _buildSite91MdVideoInfo(context, v);
      }

      // PornHub 走独立的详情面板（下载/最爱/添加/分享 + 分类标签 + 相关/推荐/评论/片单）。
      // 91 的版式与调用链**完全不动** —— 只有识别为 PornHub 的条目才分流。
      if (_isPornHubVideo(v)) {
        return _buildPornHubVideoInfo(context);
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 视频标题
            Text(
              v.title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 10),
            // 播放量与发布时间
            Row(
              children: [
                Icon(
                  Icons.play_circle_outline,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  v.viewsStr ?? '1.2万',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
                const SizedBox(width: 14),
                Icon(
                  Icons.access_time,
                  size: 14,
                  color: theme.colorScheme.outline,
                ),
                const SizedBox(width: 4),
                Text(
                  v.publishedAt != null && v.publishedAt!.isNotEmpty
                      ? '发布于 ${v.publishedAt}'
                      : '发布时间未知',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            // UP主卡片
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => AppNavigator.toAuthor(v.author),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 18,
                            backgroundColor: theme.colorScheme.primaryContainer,
                            child: Text(
                              v.author.isNotEmpty
                                  ? v.author[0].toUpperCase()
                                  : 'U',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  v.author,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '作品UP主',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: theme.colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Obx(() {
                        final userSvc = Get.find<UserService>();
                        final isSub = userSvc.isSubscribed(v.author);
                        return FilledButton.icon(
                          style: FilledButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            backgroundColor: isSub
                                ? theme.colorScheme.surfaceContainerHigh
                                : theme.colorScheme.primary,
                            foregroundColor: isSub
                                ? theme.colorScheme.onSurfaceVariant
                                : Colors.white,
                          ),
                          icon: Icon(isSub ? Icons.check : Icons.add, size: 15),
                          label: Text(
                            isSub ? '已关注' : '关注',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          onPressed: () {
                            userSvc.toggleSubscription(v.author);
                            AppToast.show(
                              userSvc.isSubscribed(v.author)
                                  ? '已关注 UP 主「${v.author}」'
                                  : '已取消关注',
                            );
                          },
                        );
                      }),
                      const SizedBox(width: 6),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        icon: const Icon(
                          Icons.person_search_outlined,
                          size: 15,
                        ),
                        label: const Text('作品', style: TextStyle(fontSize: 12)),
                        onPressed: () => AppNavigator.toAuthor(v.author),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 动作按钮栏（下载、收藏、稍后再看、分享）
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildActionButton(
                  context: context,
                  icon: Icons.download_for_offline_outlined,
                  label: '下载',
                  onTap: () => _enqueueDownload(video: v),
                ),
                Obx(() {
                  final userSvc = Get.find<UserService>();
                  final isFav = userSvc.isVideoInAnyFolder(v.id);
                  return _buildActionButton(
                    context: context,
                    icon: isFav
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    label: isFav ? '已收藏' : '收藏',
                    iconColor: isFav ? theme.colorScheme.primary : null,
                    onTap: () => _showFavoriteBottomSheet(context, v),
                  );
                }),
                Obx(() {
                  final userSvc = Get.find<UserService>();
                  final inWl = userSvc.isInWatchLater(v.id);
                  return _buildActionButton(
                    context: context,
                    icon: inWl
                        ? Icons.watch_later_rounded
                        : Icons.watch_later_outlined,
                    label: inWl ? '已添加' : '稍后再看',
                    iconColor: inWl ? theme.colorScheme.primary : null,
                    onTap: () => userSvc.toggleWatchLater(v),
                  );
                }),
                _buildActionButton(
                  context: context,
                  icon: Icons.copy_outlined,
                  label: '分享',
                  onTap: () {
                    final url = v.detailUrl ?? v.id;
                    Clipboard.setData(ClipboardData(text: url));
                    AppToast.show('已复制链接: $url');
                  },
                ),
              ],
            ),
          ],
        ),
      );
    });
  }

  /// 取 Hanime1 播放页附加元数据（点赞/评论数/上传者/标签计数/所属清单）。
  ///
  /// 用 `detailUrl` 指向的站点判定，而不是「当前激活源」—— 用户可能从 91 的
  /// 收藏或历史里点开一个 hanime1 视频，那时激活源并不是 hanime1。
  /// 直接问 [Hanime1Source] 要缓存：只有它解析过的视频才会返回非 null。
  Hanime1VideoExtra? _hanime1ExtraFor(VideoItem v) {
    final src = SourceRegistry.byId('hanime1');
    if (src is! Hanime1Source) return null;
    return src.getExtra(v.id);
  }

  /// 这个视频是不是 Hanime1 的。
  ///
  /// 与 [_hanime1ExtraFor] 的区别：这里**不依赖详情是否已解析**。
  /// 播放页的 Tab（相關影片 / 評論）只要有视频地址就能显示，
  /// 不应该因为缓存里还没有 extra 而整个消失。
  ///
  /// 判据有两级，都不看「当前激活源」—— 用户可能从 91 的收藏或历史里
  /// 点开一个 hanime1 视频，那时激活源并不是 hanime1：
  /// 1. `detailUrl` 指向 hanime1.me（所有 hanime1 条目都会带这个字段）；
  /// 2. 兜底：`detailUrl` 缺失时，看 [Hanime1Source] 是否解析过这个 id
  ///    （只有它才会往 `_extraCache` 里写）。
  bool _isHanime1Video(VideoItem? v) {
    if (v == null) return false;
    final url = v.detailUrl ?? '';
    if (url.contains('hanime1.me')) return true;
    return _hanime1ExtraFor(v) != null;
  }

  /// 这个视频是不是 PornHub 的。
  ///
  /// 以 `detailUrl` 的主机名为准：91 的 `detailUrl` 指向自己的域名，绝不会命中。
  /// 只有 `detailUrl` 缺失时才兜底看当前激活源 —— 否则「激活源是 pornhub 时打开
  /// 一个 91 收藏」会被误判成 PornHub，版式跑错。
  bool _isPornHubVideo(VideoItem? v) {
    if (v == null) return false;
    final url = v.detailUrl ?? '';
    if (url.isNotEmpty) {
      final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
      return host == 'pornhub.com' || host.endsWith('.pornhub.com');
    }
    if (!Get.isRegistered<VideoSource>()) return false;
    try {
      return Get.find<VideoSource>().id == 'pornhub';
    } catch (_) {
      return false;
    }
  }

  /// PornHub 详情面板：动作行 / 分类标签 / 四个 Tab 全在面板内部自管，
  /// 这里只把「下载」与「原地换片」两个既有能力透传进去。
  Widget _buildPornHubVideoInfo(BuildContext context) {
    return Obx(() {
      final v = controller.video.value;
      if (v == null) return const SizedBox.shrink();
      return PornHubVideoInfoPanel(
        video: v,
        onDownload: () => _enqueueDownload(video: v),
        onPlayVideo: controller.switchVideo,
      );
    });
  }

  // --------------------------------------------- 播放器下方信息区的滚动容器
  //
  // hanime1 与 91 在这里走**两套互不影响**的实现：
  //
  // - hanime1 → [CustomScrollView] + sliver。
  //   官网一部片子的「相關影片」实测会给到 **95 条**（抓 watch 页 HTML 数
  //   `/watch?v=` 去重得到），而 91 那套 [_buildRelatedSection] 用的是
  //   `ListView.separated(shrinkWrap: true)` —— `shrinkWrap` 要求它在**布局阶段**
  //   就把全部子项构建并测量出来，于是打开播放页的瞬间会一次性构建 95 张卡片、
  //   并发 95 次封面请求。换成 [SliverList] 后只构建可见的那几条。
  //
  // - 91 → 保持原有 `ListView(children:)`，一行未改。
  Widget _buildPlayerBody(BuildContext context) {
    final v = controller.video.value;

    if (v == null || !_isHanime1Video(v)) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          _buildVideoInfo(context),
          // PornHub 的四个 Tab 已经内含在信息面板里，这里不再追加 91 的
          // 「相关推荐」直排区，避免同一页出现两块相关视频。91 行为不变。
          if (!_isPornHubVideo(v)) ...[
            const Divider(height: 1, thickness: 0.5),
            _buildInfoTabs(context),
          ],
        ],
      );
    }

    // 换片时把 Tab 复位到「相關影片」。
    // 这里直接改字段而不 setState：当前这一帧本来就在重建，输出用的已是新值。
    if (_tabVideoId != v.id) {
      _tabVideoId = v.id;
      _hanime1Tab = 0;
    }
    final commentCount = _hanime1ExtraFor(v)?.commentCount ?? '';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildVideoInfo(context)),
        const SliverToBoxAdapter(child: Divider(height: 1, thickness: 0.5)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
            child: Row(
              children: [
                _buildTabButton(index: 0, label: '相關影片', badge: ''),
                const SizedBox(width: 10),
                _buildTabButton(index: 1, label: '評論', badge: commentCount),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1, thickness: 0.5)),
        // 关键点：`#comment-section-wrapper` 初始内容只有一个 loading 动图，
        // **点「評論」才会** `GET /loadComment` 把评论灌进去。所以只在切到
        // 「評論」时才挂载 [Hanime1CommentsSection]（挂载即拉取），
        // 避免一进播放页就并发 40 个评论头像请求。
        if (_hanime1Tab == 0)
          _buildRelatedSliver(context)
        else
          SliverToBoxAdapter(
            child: Hanime1CommentsSection(
              videoId: v.id,
              countText: commentCount,
            ),
          ),
      ],
    );
  }

  /// hanime1 的「相關影片」列表（官网双列卡片）。
  ///
  /// 与 91 用的 [_buildRelatedSection] 的唯一区别是换成 [SliverList]，
  /// 只构建可见项。**没有**动 91 的实现。
  ///
  /// 官网这里不放「相关推荐 / 共 N 条」这类标题 —— `#related-tabcontent`
  /// 进去就是卡片列表，Tab 按钮本身已经是标题了。
  Widget _buildRelatedSliver(BuildContext context) {
    return Obx(() {
      final list = controller.relatedVideos;
      if (list.isEmpty) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                '暂无相关推荐',
                style: TextStyle(color: context.cTextSub, fontSize: 13),
              ),
            ),
          ),
        );
      }

      return Hanime1VideoGridSliver(
        items: list.toList(growable: false),
        padding: const EdgeInsets.fromLTRB(7, 8, 7, 18),
        onTapItem: controller.switchVideo,
      );
    });
  }

  // --------------------------------------------- 資訊區 Tab（相關影片 / 評論）
  //
  // 官网 `#tablinks-wrapper` 只有两个按钮：
  // ```
  // <button id="defaultOpen" data-tabcontent="related-tabcontent">相關影片</button>
  // <button id="comment-tablink" data-foreignid="102422" data-type="video"
  //         data-tabcontent="comment-tabcontent">評論 <span id="tab-comments-count">40</span></button>
  // ```
  // 关键点：`#comment-section-wrapper` 初始内容只有一个 loading 动图，
  // **点「評論」才会** `GET /loadComment` 把评论灌进去。
  // 所以这里只在切到「評論」时才挂载 [Hanime1CommentsSection]（挂载即拉取），
  // 避免一进播放页就并发 40 个评论头像请求。
  //
  // 非 Hanime1 视频不引入 Tab，保持原来的「信息 + 相关推荐」直排。
  //
  // 注意：hanime1 现在由 [_buildPlayerBody] 直接分流到 sliver 版（原因见那里的
  // 注释），所以本方法实际上只服务 91。下面那条 hanime1 分支保留原样是为了
  // 不动 91 的调用链，正常不会执行。
  Widget _buildInfoTabs(BuildContext context) {
    return Obx(() {
      final v = controller.video.value;
      if (v == null) return const SizedBox.shrink();

      if (!_isHanime1Video(v)) return _buildRelatedSection(context);

      // 换片时把 Tab 复位到「相關影片」。
      // 这里直接改字段而不 setState：当前这一帧本来就在重建，输出用的已是新值。
      if (_tabVideoId != v.id) {
        _tabVideoId = v.id;
        _hanime1Tab = 0;
      }

      final commentCount = _hanime1ExtraFor(v)?.commentCount ?? '';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // #tablinks-wrapper { margin-top:30px; font-weight:bold }
          //   + .mobile-padding { padding:0 10px }
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 14, 10, 4),
            child: Row(
              children: [
                _buildTabButton(index: 0, label: '相關影片', badge: ''),
                const SizedBox(width: 10),
                _buildTabButton(index: 1, label: '評論', badge: commentCount),
              ],
            ),
          ),
          const Divider(height: 1, thickness: 0.5),
          if (_hanime1Tab == 0)
            _buildRelatedSection(context)
          else
            Hanime1CommentsSection(videoId: v.id, countText: commentCount),
        ],
      );
    });
  }

  Widget _buildSite91MdVideoInfo(BuildContext context, VideoItem video) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            video.title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              const Text('91麻豆'),
              if (video.viewsStr?.isNotEmpty ?? false) Text(video.viewsStr!),
              if (video.publishedAt?.isNotEmpty ?? false)
                Text(video.publishedAt!),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => _enqueueDownload(video: video),
                icon: const Icon(Icons.download_rounded),
                label: const Text('下载'),
                style: FilledButton.styleFrom(minimumSize: const Size(110, 44)),
              ),
              Obx(() {
                final saved = Get.find<UserService>().isVideoInAnyFolder(
                  video.id,
                );
                return OutlinedButton.icon(
                  onPressed: () => _showFavoriteBottomSheet(context, video),
                  icon: Icon(
                    saved
                        ? Icons.bookmark_rounded
                        : Icons.bookmark_border_rounded,
                  ),
                  label: Text(saved ? '已收藏' : '收藏'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(110, 44),
                  ),
                );
              }),
            ],
          ),
        ],
      ),
    );
  }

  /// 单个 Tab 按钮。官网没给 `.tablinks` 写样式（用浏览器默认按钮外观），
  /// 这里按页面的深色底做等价处理：选中白色加粗，未选中灰色。
  Widget _buildTabButton({
    required int index,
    required String label,
    required String badge,
  }) {
    final selected = _hanime1Tab == index;

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () {
        if (_hanime1Tab == index) return;
        setState(() => _hanime1Tab = index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: selected ? context.cTextMain : context.cTextSub,
              ),
            ),
            if (badge.isNotEmpty) ...[
              const SizedBox(width: 6),
              // #tab-comments-count { color:white; background-color:red;
              //   font-size:12px; border-radius:10px; padding:1px 5px }
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: context.cError,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  badge,
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------- 操作按钮

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    Color? iconColor,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final color = iconColor ?? theme.colorScheme.onSurfaceVariant;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFavoriteBottomSheet(BuildContext context, VideoItem video) {
    final userSvc = Get.find<UserService>();
    final theme = Theme.of(context);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                  child: Row(
                    children: [
                      const Text(
                        '收藏到收藏夹',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      TextButton.icon(
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('新建收藏夹'),
                        onPressed: () => _showCreateFolderDialog(ctx),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: Obx(() {
                    final folders = userSvc.favorites.keys.toList();
                    return ListView.builder(
                      shrinkWrap: true,
                      itemCount: folders.length,
                      itemBuilder: (context, idx) {
                        final folder = folders[idx];
                        final inFolder = userSvc.isVideoInFolder(
                          folder,
                          video.id,
                        );
                        final count = userSvc.favorites[folder]?.length ?? 0;

                        return ListTile(
                          leading: Icon(
                            inFolder
                                ? Icons.folder_special
                                : Icons.folder_outlined,
                            color: inFolder
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outline,
                          ),
                          title: Text(folder),
                          subtitle: Text('共 $count 个视频'),
                          trailing: Checkbox(
                            value: inFolder,
                            activeColor: theme.colorScheme.primary,
                            onChanged: (val) {
                              if (val == true) {
                                userSvc.addVideoToFolder(folder, video);
                              } else {
                                userSvc.removeVideoFromFolder(folder, video.id);
                              }
                            },
                          ),
                          onTap: () {
                            if (inFolder) {
                              userSvc.removeVideoFromFolder(folder, video.id);
                            } else {
                              userSvc.addVideoToFolder(folder, video);
                            }
                          },
                        );
                      },
                    );
                  }),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCreateFolderDialog(BuildContext context) {
    final textController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建收藏夹'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(hintText: '收藏夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final name = textController.text.trim();
              if (name.isNotEmpty) {
                final success = Get.find<UserService>().createFolder(name);
                if (success) {
                  Navigator.of(ctx).pop();
                  AppToast.show('已创建收藏夹：$name');
                } else {
                  AppToast.show('收藏夹已存在或名称无效');
                }
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 相关推荐列表
  Widget _buildRelatedSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: Row(
            children: [
              Icon(Icons.recommend, size: 18, color: context.cAccent),
              const SizedBox(width: 6),
              const Text(
                '相关推荐',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Obx(
                () => Text(
                  '共 ${controller.relatedVideos.length} 条',
                  style: TextStyle(fontSize: 11, color: context.cTextSub),
                ),
              ),
            ],
          ),
        ),
        Obx(() {
          final list = controller.relatedVideos;
          if (list.isEmpty) {
            return Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(
                  '暂无相关推荐',
                  style: TextStyle(color: context.cTextSub, fontSize: 13),
                ),
              ),
            );
          }

          return ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: list.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 1, indent: 14, endIndent: 14),
            itemBuilder: (context, index) {
              final item = list[index];
              return BiliVideoCardH(
                video: item,
                onTap: () => controller.switchVideo(item),
              );
            },
          );
        }),
      ],
    );
  }

  void _enqueueDownload({required VideoItem video}) {
    final service = Get.find<DownloadService>();
    for (final task in service.tasks) {
      if (task.id == video.id && task.isActive) {
        AppToast.show('「${video.title}」已在下载队列中');
        return;
      }
    }
    service.enqueue(video);
    AppToast.show('已加入下载队列：${video.title}');
  }
}

enum _DragMode { none, horizontalSeek, verticalBrightness, verticalVolume }

/// 播放器多手势触控交互层
class _PlayerGestureZone extends StatefulWidget {
  const _PlayerGestureZone({
    required this.controller,
    required this.boxWidth,
    required this.boxHeight,
  });

  final PlayerController controller;
  final double boxWidth;
  final double boxHeight;

  @override
  State<_PlayerGestureZone> createState() => _PlayerGestureZoneState();
}

class _PlayerGestureZoneState extends State<_PlayerGestureZone> {
  Offset? _doubleTapPosition;
  Offset? _lastTapPosition;
  Offset _dragStartPosition = Offset.zero;
  _DragMode _dragMode = _DragMode.none;
  double _accumulatedDx = 0.0;
  double _accumulatedDy = 0.0;

  static const double _kDragThreshold = 10.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (details) {
        _lastTapPosition = details.localPosition;
      },
      onTap: () {
        AppLogger.i('Player', '点击播放器屏幕: 切换控制层显隐');
        widget.controller.toggleControls();
      },
      onDoubleTapDown: (details) {
        _doubleTapPosition = details.localPosition;
      },
      onDoubleTap: () {
        final pos = _doubleTapPosition ?? _lastTapPosition;
        if (pos == null) return;
        final dx = pos.dx;
        final w = widget.boxWidth;
        AppLogger.i(
          'Player',
          '双击播放器: dx=$dx, w=$w (比例: ${(dx / w).toStringAsFixed(2)})',
        );
        if (dx < w * 0.35) {
          widget.controller.onDoubleTapLeft();
        } else if (dx > w * 0.65) {
          widget.controller.onDoubleTapRight();
        } else {
          widget.controller.onDoubleTapCenter();
        }
      },
      onLongPressStart: (_) => widget.controller.startSpeeding(),
      onLongPressEnd: (_) => widget.controller.stopSpeeding(),
      onPanStart: (details) {
        _dragStartPosition = details.localPosition;
        _dragMode = _DragMode.none;
        _accumulatedDx = 0.0;
        _accumulatedDy = 0.0;
      },
      onPanUpdate: (details) {
        final deltaDx = details.delta.dx;
        final deltaDy = details.delta.dy;
        _accumulatedDx += deltaDx;
        _accumulatedDy += deltaDy;

        if (_dragMode == _DragMode.none) {
          if (_accumulatedDx.abs() > _kDragThreshold ||
              _accumulatedDy.abs() > _kDragThreshold) {
            if (_accumulatedDx.abs() >= _accumulatedDy.abs()) {
              _dragMode = _DragMode.horizontalSeek;
              widget.controller.onHorizontalDragStart();
            } else {
              if (_dragStartPosition.dx < widget.boxWidth * 0.5) {
                _dragMode = _DragMode.verticalBrightness;
              } else {
                _dragMode = _DragMode.verticalVolume;
                widget.controller.beginVolumeGesture();
              }
            }
          }
        }

        switch (_dragMode) {
          case _DragMode.horizontalSeek:
            widget.controller.onHorizontalDragUpdate(deltaDx, widget.boxWidth);
            break;
          case _DragMode.verticalBrightness:
            widget.controller.onVerticalDragLeft(deltaDy, widget.boxHeight);
            break;
          case _DragMode.verticalVolume:
            widget.controller.onVerticalDragRight(deltaDy, widget.boxHeight);
            break;
          case _DragMode.none:
            break;
        }
      },
      onPanEnd: (_) {
        if (_dragMode == _DragMode.horizontalSeek) {
          widget.controller.onHorizontalDragEnd();
        }
        if (_dragMode == _DragMode.verticalVolume) {
          widget.controller.endVolumeGesture();
        }
        _dragMode = _DragMode.none;
      },
      onPanCancel: () {
        if (_dragMode == _DragMode.horizontalSeek) {
          widget.controller.onHorizontalDragEnd();
        }
        if (_dragMode == _DragMode.verticalVolume) {
          widget.controller.endVolumeGesture();
        }
        _dragMode = _DragMode.none;
      },
    );
  }
}
