import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/modules/player/player_view.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/user_service.dart';

import 'active_player_release_contract_test.dart'
    show ActiveNativePlayers, ReleaseSource, releaseItem;

class ErrorNativePlayers extends ActiveNativePlayers {
  @override
  Widget buildView(int playerId) => const SizedBox.expand();
}

class NoHistoryUser extends UserService {
  final subscriptionState = false.obs;
  @override
  bool isSubscribed(String author) => subscriptionState.value;
  @override
  void recordHistory(
    VideoItem video, {
    int positionMs = 0,
    int durationMs = 0,
  }) {}
}

void main() {
  for (final action in ['retry', 'topRefresh', 'pause']) {
    for (final width in [400.0, 576.0]) {
      testWidgets('$action remains reachable at width $width', (tester) async {
        final previous = VideoPlayerPlatform.instance;
        final native = ErrorNativePlayers();
        VideoPlayerPlatform.instance = native;
        Get.testMode = true;
        Get.put<VideoSource>(ReleaseSource());
        Get.put<UserService>(NoHistoryUser());
        PreloadService.instance.preloadCount.value = 0;
        tester.view.physicalSize = Size(width, 1280);
        tester.view.devicePixelRatio = 1;
        final key = GlobalKey();
        try {
          await tester.pumpWidget(
            GetMaterialApp(
              home: PlayerView(key: key, videoItem: releaseItem('retry')),
            ),
          );
          final c =
              (key.currentState as dynamic).controller as PlayerController;
          for (var n = 0; n < 50 && !c.isInitialized.value; n++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(c.isInitialized.value, true);
          c.error.value = 'Video player had error androidx.media3.exoplayer.ExoPlaybackException: Source error';
          if (action == 'pause') c.error.value = null;
          c.showControls.value = true;
          await tester.pump(const Duration(milliseconds: 300));
          final oldPlayer = c.videoPlayerController;
          final button = action == 'retry'
              ? find.widgetWithText(FilledButton, '重试加载')
              : find.byIcon(
                  action == 'topRefresh' ? Icons.refresh : Icons.pause_rounded,
                );
          expect(button, findsOneWidget);
          await tester.tap(button, warnIfMissed: false);
          if (action == 'pause') {
            expect(c.videoPlayerController, same(oldPlayer));
            expect(oldPlayer!.value.isPlaying, false);
          } else {
            expect(
              c.videoPlayerController,
              isNot(same(oldPlayer)),
              reason: 'Retry must invoke existing reload and detach old SDK',
            );
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 350));
          Get.reset();
          VideoPlayerPlatform.instance = previous;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      });
    }
  }
}
