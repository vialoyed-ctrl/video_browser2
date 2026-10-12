import 'dart:async';

import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/services/player_service.dart';
import 'package:video_browser/app/services/preload_service.dart';

import 'active_player_release_contract_test.dart'
    show ActiveNativePlayers, ReleaseSource, releaseItem, until;

class ScrubNativePlayers extends ActiveNativePlayers {
  Completer<void>? seekGate, nextSeekGate;
  final seekRecords = <(int, Duration)>[];
  void Function()? onSeekDispatched;
  final seekCalls = <Duration>[];
  final playCalls = <int>[];
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seekCalls.add(position);
    seekRecords.add((playerId, position));
    final callback = onSeekDispatched;
    onSeekDispatched = null;
    callback?.call();
    final gate = playerId == 1 ? seekGate : nextSeekGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
    await super.play(playerId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previous;
  late ScrubNativePlayers native;
  late PlayerController controller;
  final pending = <Future<void>>[];
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    native = ScrubNativePlayers();
    VideoPlayerPlatform.instance = native;
    Get.put<VideoSource>(ReleaseSource());
    PreloadService.instance.preloadCount.value = 0;
    PlayerService.instance.clearPreplay();
    controller = PlayerController();
    pending.clear();
  });
  tearDown(() async {
    for (final gate in native.pauseGates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    if (native.seekGate != null && !native.seekGate!.isCompleted) {
      native.seekGate!.complete();
    }
    if (native.nextSeekGate != null && !native.nextSeekGate!.isCompleted) {
      native.nextSeekGate!.complete();
    }
    await Future.wait(pending);
    controller.onClose();
    await until(() => native.active.isEmpty);
    for (final stream in native.events.values) {
      await stream.close();
    }
    VideoPlayerPlatform.instance = previous;
    Get.reset();
  });
  Future<void> open() async {
    await controller.switchVideo(releaseItem('scrub'));
    await until(
      () => native.played.contains(1) && controller.isInitialized.value,
    );
    expect(controller.playing.value, isTrue);
  }

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test(
    'active drag resumes only after pause and final seek acknowledgements',
    () async {
      await open();
      final initialPlays = native.playCalls.length;
      native.pauseGates[1] = Completer<void>();
      native.seekGate = Completer<void>();
      controller.beginScrub(const Duration(seconds: 1));
      controller.updateScrub(const Duration(seconds: 2));
      await controller.endScrub();
      await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
      await settle();
      expect(native.playCalls.length, initialPlays);
      native.pauseGates[1]!.complete();
      await settle();
      expect(native.playCalls.length, initialPlays);
      native.seekGate!.complete();
      await until(() => native.playCalls.length == initialPlays + 1);
      expect(native.active, {1});
    },
  );
  test(
    'closing mid-drag releases native player despite held pause reply',
    () async {
      await open();
      native.pauseGates[1] = Completer<void>();
      controller.beginScrub(const Duration(seconds: 1));
      controller.updateScrub(const Duration(seconds: 2));
      await settle();
      controller.onClose();
      await until(() => native.released.contains(1));
      expect(native.active, isEmpty);
    },
  );
  test('closing after drag end releases native player despite held final seek reply', () async {
    await open();
    native.seekGate = Completer<void>();
    controller.beginScrub(const Duration(seconds: 1));
    controller.updateScrub(const Duration(seconds: 2));
    await controller.endScrub();
    await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
    final playsBeforeClose = native.playCalls.length;
    controller.onClose();
    await until(() => native.released.contains(1));
    native.seekGate!.complete();
    await settle();
    expect(native.active, isEmpty);
    expect(native.playCalls.length, playsBeforeClose);
  });

  test(
    'closing horizontal drag releases native player despite held pause reply',
    () async {
      await open();
      native.pauseGates[1] = Completer<void>();
      controller.onHorizontalDragStart();
      controller.onHorizontalDragUpdate(30, 300);
      controller.onHorizontalDragEnd();
      await settle();
      controller.onClose();
      await until(() => native.released.contains(1));
      expect(native.active, isEmpty);
    },
  );
  test('switching during held drag seek disposes old player and ignores late resume', () async {
    await open();
    native.seekGate = Completer<void>();
    controller.beginScrub(const Duration(seconds: 1));
    controller.updateScrub(const Duration(seconds: 2));
    await controller.endScrub();
    await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
    final switching = controller.switchVideo(releaseItem('next'));
    pending.add(switching);
    await until(() => native.released.contains(1));
    await switching;
    await until(() => native.played.contains(2));
    expect(controller.video.value?.id, 'active-next');
    expect(native.active, {2});
    native.seekGate!.complete();
    await settle();
    expect(native.playCalls.where((id) => id == 1).length, 1);
    expect(native.active, {2});
  });

  test('late old seek cannot clear the replacement drag pump or consume its target', () async {
    await open();
    native.seekGate = Completer<void>();
    controller.beginScrub(const Duration(seconds: 1));
    controller.updateScrub(const Duration(seconds: 2));
    await controller.endScrub();
    await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
    final switching = controller.switchVideo(releaseItem('next'));
    pending.add(switching);
    await until(() => native.released.contains(1));
    await switching;
    await until(() => native.played.contains(2));
    native.nextSeekGate = Completer<void>();
    controller.beginScrub(const Duration(seconds: 3));
    controller.updateScrub(const Duration(seconds: 4));
    await until(() => native.seekRecords.any((r) => r.$1 == 2));
    final oldSeekCount = native.seekRecords.where((r) => r.$1 == 1).length;
    native.seekGate!.complete();
    await settle();
    controller.updateScrub(const Duration(seconds: 5));
    await settle();
    expect(native.seekRecords.where((r) => r.$1 == 1).length, oldSeekCount);
    expect(
      native.seekRecords.where((r) => r.$1 == 2).length,
      1,
      reason:
          'The held replacement pump must retain its slot until its own reply',
    );
    expect(native.playCalls.where((id) => id == 1).length, 1);
    native.nextSeekGate!.complete();
    // The production pump intentionally throttles intermediate targets.
    final expectedTarget = (2, const Duration(seconds: 5));
    for (
      var i = 0;
      i < 100 && !native.seekRecords.contains(expectedTarget);
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(native.seekRecords, contains(expectedTarget));
    await controller.endScrub();
  });
  test(
    'late failed old final seek cannot affect replacement playback',
    () async {
      await open();
      native.seekGate = Completer<void>();
      controller.beginScrub(const Duration(seconds: 1));
      controller.updateScrub(const Duration(seconds: 2));
      await controller.endScrub();
      await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
      final switching = controller.switchVideo(releaseItem('next'));
      pending.add(switching);
      await until(() => native.released.contains(1));
      await switching;
      await until(() => native.played.contains(2));
      native.seekGate!.completeError(
        PlatformException(code: 'late_seek_failed'),
      );
      await settle();
      expect(controller.error.value, isNull);
      expect(controller.video.value?.id, 'active-next');
      expect(native.active, {2});
      expect(native.playCalls.where((id) => id == 1).length, 1);
    },
  );

  test(
    'synchronous close during seek dispatch still observes a late failed reply',
    () async {
      await open();
      native.seekGate = Completer<void>();
      native.onSeekDispatched = controller.onClose;
      controller.beginScrub(const Duration(seconds: 1));
      controller.updateScrub(const Duration(seconds: 2));
      await until(() => native.released.contains(1));
      native.seekGate!.completeError(
        PlatformException(code: 'reentrant_seek_failed'),
      );
      await settle();
      expect(native.active, isEmpty);
      expect(controller.error.value, isNull);
    },
  );

  test(
    'active drag waits for held pause even when final seek acknowledges first',
    () async {
      await open();
      final initialPlays = native.playCalls.length;
      native.pauseGates[1] = Completer<void>();
      native.seekGate = Completer<void>();
      controller.beginScrub(const Duration(seconds: 1));
      controller.updateScrub(const Duration(seconds: 2));
      await controller.endScrub();
      await until(() => native.seekCalls.contains(const Duration(seconds: 2)));
      native.seekGate!.complete();
      await settle();
      expect(native.playCalls.length, initialPlays);
      native.pauseGates[1]!.complete();
      await until(() => native.playCalls.length == initialPlays + 1);
      expect(native.active, {1});
    },
  );
}
