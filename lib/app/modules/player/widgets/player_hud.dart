/// 播放器各类手势交互 HUD 浮层（仿哔哩哔哩/PiliPlus 风格）。
library;

import 'package:flutter/material.dart';

import '../../../core/app_theme.dart';

/// 屏幕中央亮度调节 HUD（对齐用户图示：正中央黑透胶囊 [太阳图标] [16%] + 左侧纤细垂直进度条）
class BrightnessHud extends StatelessWidget {
  const BrightnessHud({super.key, required this.brightness});

  final double brightness; // 0.0 - 1.0

  @override
  Widget build(BuildContext context) {
    final percent = (brightness * 100).round().clamp(0, 100);

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // 1. 左侧边缘纤细垂直指示线（对齐图1左边缘触控反馈）
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: 3.5,
                  height: 115,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0x4DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: brightness.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.playerAccent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 2. 正中央半透明黑底胶囊指示器（对齐图1核心元素：太阳图标 + 16%）
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xBA000000),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.brightness_7_rounded,
                      color: AppTheme.playerAccent,
                      size: 22,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$percent%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
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
}

/// 屏幕中央音量调节 HUD（对齐用户图示：正中央黑透胶囊 [喇叭图标] [21%] + 左侧纤细垂直进度条）
class VolumeHud extends StatelessWidget {
  const VolumeHud({super.key, required this.volume});

  final double volume; // 0.0 - 100.0

  @override
  Widget build(BuildContext context) {
    final percent = volume.round().clamp(0, 100);
    final IconData icon = percent == 0
        ? Icons.volume_off_rounded
        : (percent <= 50 ? Icons.volume_down_rounded : Icons.volume_up_rounded);

    return Positioned.fill(
      child: IgnorePointer(
        child: Stack(
          children: [
            // 1. 左侧边缘纤细垂直指示线（对齐图2左边缘触控反馈）
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: Container(
                  width: 3.5,
                  height: 115,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: const Color(0x4DFFFFFF),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      heightFactor: (volume / 100.0).clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.playerAccent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 2. 正中央半透明黑底胶囊指示器（对齐图2核心元素：喇叭图标 + 21%）
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xBA000000),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, color: AppTheme.playerAccent, size: 22),
                    const SizedBox(width: 8),
                    Text(
                      '$percent%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
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
}

/// 屏幕中央滑动 Seek 预览 HUD（包含动态游标进度条与对准时间）
class SeekPreviewHud extends StatelessWidget {
  const SeekPreviewHud({
    super.key,
    required this.targetPosition,
    required this.totalDuration,
    required this.deltaSeconds,
  });

  final Duration targetPosition;
  final Duration totalDuration;
  final int deltaSeconds;

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (d.inHours > 0) {
      final h = d.inHours.toString().padLeft(2, '0');
      return '$h:$m:$s';
    }
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isForward = deltaSeconds >= 0;
    final deltaStr = isForward ? '+$deltaSeconds' : '$deltaSeconds';
    final icon = isForward
        ? Icons.fast_forward_rounded
        : Icons.fast_rewind_rounded;
    final totalMs = totalDuration.inMilliseconds;
    final targetMs = targetPosition.inMilliseconds;
    final double proportion = totalMs > 0
        ? (targetMs / totalMs).clamp(0.0, 1.0)
        : 0.0;

    const barWidth = 220.0;
    const barHeight = 5.0;
    const thumbRadius = 6.0;

    return Center(
      child: Container(
        width: 260,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0xEE1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24, width: 0.8),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 16, spreadRadius: 4),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 1. 方向与偏移秒数
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: AppTheme.playerAccent, size: 22),
                const SizedBox(width: 6),
                Text(
                  '$deltaStr 秒',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // 2. 目标时间 / 总时间对准显示
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  _format(targetPosition),
                  style: const TextStyle(
                    color: AppTheme.playerAccent,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '/ ${_format(totalDuration)}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 3. 动态滑动进度条（滑块与填充条实时跟随对齐）
            SizedBox(
              width: barWidth,
              height: thumbRadius * 2,
              child: Stack(
                alignment: Alignment.centerLeft,
                children: [
                  // 背景槽
                  Container(
                    width: barWidth,
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(barHeight / 2),
                    ),
                  ),
                  // 高亮进度填充
                  Container(
                    width: (barWidth * proportion).clamp(0.0, barWidth),
                    height: barHeight,
                    decoration: BoxDecoration(
                      color: AppTheme.playerAccent,
                      borderRadius: BorderRadius.circular(barHeight / 2),
                    ),
                  ),
                  // 发光游标（对准当前时间点）
                  Positioned(
                    left: (proportion * (barWidth - thumbRadius * 2)).clamp(
                      0.0,
                      barWidth - thumbRadius * 2,
                    ),
                    child: Container(
                      width: thumbRadius * 2,
                      height: thumbRadius * 2,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: const [
                          BoxShadow(
                            color: AppTheme.playerBuffer,
                            blurRadius: 6,
                            spreadRadius: 2,
                          ),
                        ],
                        border: Border.all(
                          color: AppTheme.playerAccent,
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部 2.0X 倍速播放中 HUD（长按手势触发）
class SpeedingHud extends StatelessWidget {
  const SpeedingHud({super.key});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        margin: const EdgeInsets.only(top: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.playerAccent,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: AppTheme.playerGlow,
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.fast_forward_rounded, color: Colors.black87, size: 18),
            SizedBox(width: 6),
            Text(
              '2.0X 倍速播放中',
              style: TextStyle(
                color: Colors.black87,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
