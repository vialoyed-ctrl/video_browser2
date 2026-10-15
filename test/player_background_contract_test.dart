import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/player_service.dart';

import 'active_player_release_contract_test.dart'
    show ActiveNativePlayers, ReleaseSource, releaseItem, until;

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final initiallyPlaying in [true, false]) {
    test('background resume preserves playing=$initiallyPlaying', () async {
      final previous = VideoPlayerPlatform.instance;
      final native = ActiveNativePlayers();
      VideoPlayerPlatform.instance = native;
      Get.testMode = true;
      Get.put<VideoSource>(ReleaseSource());
      PreloadService.instance.preloadCount.value = 0;
      PlayerService.instance.clearPreplay();
      final c = PlayerController();
      try {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await c.switchVideo(releaseItem('background'));
        await until(
          () =>
              c.isInitialized.value && c.videoPlayerController!.value.isPlaying,
        );
        if (!initiallyPlaying) {
          await c.pause();
        }
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await Future<void>.delayed(Duration.zero);
        expect(c.videoPlayerController!.value.isPlaying, false);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await Future<void>.delayed(Duration.zero);
        expect(
          c.videoPlayerController!.value.isPlaying,
          initiallyPlaying,
          reason: 'Returning to foreground must respect prior user pause',
        );
      } finally {
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        c.onClose();
        await until(() => native.active.isEmpty);
        for (final s in native.events.values) {
          await s.close();
        }
        Get.reset();
        VideoPlayerPlatform.instance = previous;
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  }
}
