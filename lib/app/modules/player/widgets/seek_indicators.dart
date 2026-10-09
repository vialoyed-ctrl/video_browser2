/// 播放器双击快退/快进即时反馈指示层。
/// 彻底消除延迟等待定时器，点击瞬间 seek，指示层仅作平滑视觉呈现与连击秒数展示。
library;

import 'package:flutter/material.dart';

class BackwardSeekIndicator extends StatelessWidget {
  const BackwardSeekIndicator({
    super.key,
    this.seconds = 5,
    this.onSubmitted,
    this.step,
  });

  final int seconds;
  final ValueChanged<Duration>? onSubmitted;
  final Duration? step;

  @override
  Widget build(BuildContext context) {
    final displaySeconds = seconds > 0 ? seconds : (step?.inSeconds ?? 5);

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: const Icon(
                  Icons.fast_rewind_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '-$displaySeconds 秒',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ForwardSeekIndicator extends StatelessWidget {
  const ForwardSeekIndicator({
    super.key,
    this.seconds = 10,
    this.onSubmitted,
    this.step,
  });

  final int seconds;
  final ValueChanged<Duration>? onSubmitted;
  final Duration? step;

  @override
  Widget build(BuildContext context) {
    final displaySeconds = seconds > 0 ? seconds : (step?.inSeconds ?? 10);

    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: 1.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: const Icon(
                  Icons.fast_forward_rounded,
                  size: 36,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '+$displaySeconds 秒',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 4, color: Colors.black87)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
