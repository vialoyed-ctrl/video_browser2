import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:get/get.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';
import 'package:video_browser/app/services/preload_service.dart';
import 'package:video_browser/app/services/player_service.dart';

class ReleaseSource extends Site91Source {
  @override
  Future<VideoDetail?> fetchDetail(
    String videoId, {
    bool forceRefresh = false,
  }) async =>
      VideoDetail(video: releaseItem(Uri.parse(videoId).pathSegments.last));
}

class ActiveNativePlayers extends VideoPlayerPlatform {
  int nextId = 0;
  final active = <int>{}, played = <int>{};
  final released = <int>[];
  final subscriptionsCanceled = <int>[];
  final events = <int, StreamController<VideoEvent>>{};
  final failPause = <int>{};
  final disposeStarted = <int>[];
  final disposeGates = <int, Completer<void>>{};
  final pauseGates = <int, Completer<void>>{};
  @override
  Future<void> init() async {}
  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = ++nextId;
    active.add(id);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final stream = StreamController<VideoEvent>(
      onCancel: () {
        subscriptionsCanceled.add(playerId);
      },
    );
    events[playerId] = stream;
    stream.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: const Size(640, 360),
      ),
    );
    return stream.stream;
  }

  @override
  Future<void> play(int playerId) async {
    played.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    if (failPause.contains(playerId)) {
      throw PlatformException(code: 'pause_failed');
    }
    final gate = pauseGates[playerId];
    if (gate != null) await gate.future;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposeStarted.add(playerId);
    final gate = disposeGates[playerId];
    if (gate != null) await gate.future;
    active.remove(playerId);
    released.add(playerId);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}
  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {}
  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;
}

VideoItem releaseItem(String id) => VideoItem(
  id: 'active-$id',
  title: 'Active fixture',
  author: '',
  detailUrl: 'https://example.invalid/$id',
  hlsUrl: 'https://example.invalid/$id.mp4',
);

Future<void> until(bool Function() condition) async {
  for (var n = 0; n < 100 && !condition(); n++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(
    condition(),
    isTrue,
    reason: 'Expected native lifecycle boundary did not complete',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late VideoPlayerPlatform previous;
  late ActiveNativePlayers native;
  late PlayerController controller;
  final pending = <Future<void>>[];
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    native = ActiveNativePlayers();
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
    for (final gate in native.disposeGates.values) {
      if (!gate.isCompleted) gate.complete();
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
    await controller.switchVideo(releaseItem('first'));
    await until(
      () => native.played.contains(1) && controller.isInitialized.value,
    );
  }

  test(
    'active video switch releases previous native player before opening next',
    () async {
      await open();
      await controller.switchVideo(releaseItem('second'));
      await until(() => native.played.contains(2));
      expect(native.released, [1]);
      expect(native.active, {2});
      expect(controller.video.value?.id, 'active-second');
    },
  );
  test('active route close releases player despite held pause reply', () async {
    await open();
    native.pauseGates[1] = Completer<void>();
    controller.onClose();
    await until(() => native.released.contains(1));
    expect(native.active, isEmpty);
  });
  test('active switch is not blocked by previous pause reply', () async {
    await open();
    native.pauseGates[1] = Completer<void>();
    final switchTask = controller.switchVideo(releaseItem('second'));
    pending.add(switchTask);
    await until(() => native.released.contains(1));
    await until(() => native.played.contains(2));
    expect(native.active, {2});
    expect(controller.video.value?.id, 'active-second');
  });

  test('active cleanup still releases native player if pause fails', () async {
    await open();
    native.failPause.add(1);
    await controller.switchVideo(releaseItem('second'));
    await until(() => native.played.contains(2));
    expect(native.released, [1]);
    expect(native.active, {2});
  });
  test(
    'active takeover waits for old native disposal acknowledgement',
    () async {
      await open();
      native.disposeGates[1] = Completer<void>();
      final switching = controller.switchVideo(releaseItem('second'));
      pending.add(switching);
      await until(() => native.disposeStarted.contains(1));
      expect(native.nextId, 1);
      expect(native.active, {1});
      native.disposeGates[1]!.complete();
      await switching;
      await until(() => native.played.contains(2));
      expect(native.released, [1]);
      expect(native.active, {2});
    },
  );

  test(
    'late failed pause reply cannot revive a released player or escape cleanup',
    () async {
      await open();
      native.pauseGates[1] = Completer<void>();
      await controller.switchVideo(releaseItem('second'));
      await until(() => native.played.contains(2));
      expect(native.released, [1]);
      expect(native.subscriptionsCanceled, [1]);
      native.pauseGates[1]!.completeError(
        PlatformException(code: 'late_pause_failed'),
      );
      await Future<void>.delayed(Duration.zero);
      expect(native.active, {2});
      expect(controller.video.value?.id, 'active-second');
      expect(controller.error.value, isNull);
    },
  );

  test(
    'concurrent switches share old disposal before latest video opens',
    () async {
      await open();
      native.disposeGates[1] = Completer<void>();
      final firstSwitch = controller.switchVideo(releaseItem('second'));
      pending.add(firstSwitch);
      await until(() => native.disposeStarted.contains(1));
      final latestSwitch = controller.switchVideo(releaseItem('third'));
      pending.add(latestSwitch);
      for (var n = 0; n < 30; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(
        native.nextId,
        1,
        reason: 'No new native allocation before old disposal acknowledgement',
      );
      expect(native.active, {1});
      native.disposeGates[1]!.complete();
      await Future.wait([firstSwitch, latestSwitch]);
      await until(() => native.played.contains(2));
      expect(controller.video.value?.id, 'active-third');
      expect(native.nextId, 2);
      expect(native.released, [1]);
      expect(native.active, {2});
      await controller.switchVideo(releaseItem('fourth'));
      await until(() => native.played.contains(3));
      expect(native.released, [1, 2]);
      expect(native.active, {3});
      expect(controller.video.value?.id, 'active-fourth');
    },
  );
  test(
    'closing during shared disposal cannot allocate a stale switch target',
    () async {
      await open();
      native.disposeGates[1] = Completer<void>();
      final firstSwitch = controller.switchVideo(releaseItem('second'));
      pending.add(firstSwitch);
      await until(() => native.disposeStarted.contains(1));
      final latestSwitch = controller.switchVideo(releaseItem('third'));
      pending.add(latestSwitch);
      controller.onClose();
      for (var n = 0; n < 30; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.nextId, 1);
      expect(native.active, {1});
      native.disposeGates[1]!.complete();
      await Future.wait([firstSwitch, latestSwitch]);
      await until(() => native.active.isEmpty);
      expect(native.nextId, 1);
      expect(native.released, [1]);
    },
  );

  test('reload pending disposal cannot reopen after route close', () async {
    await open();
    native.disposeGates[1] = Completer<void>();
    final reload = controller.reload();
    pending.add(reload);
    await until(() => native.disposeStarted.contains(1));
    controller.onClose();
    native.disposeGates[1]!.complete();
    await reload;
    expect(native.nextId, 1);
    expect(native.active, isEmpty);
  });
  test('reload pending disposal cannot override a newer switch', () async {
    await open();
    native.disposeGates[1] = Completer<void>();
    final reload = controller.reload();
    pending.add(reload);
    await until(() => native.disposeStarted.contains(1));
    final latest = controller.switchVideo(releaseItem('latest'));
    pending.add(latest);
    native.disposeGates[1]!.complete();
    await Future.wait([reload, latest]);
    await until(
      () => native.active.length == 1 && native.played.contains(native.nextId),
    );
    expect(native.nextId, 2);
    expect(controller.video.value?.id, 'active-latest');
  });
  test(
    'synchronous seeking listener cannot bypass the disposal barrier',
    () async {
      await open();
      native.disposeGates[1] = Completer<void>();
      var fired = false;
      final subscription = controller.isSeeking.listen((seeking) {
        if (!seeking && !fired) {
          fired = true;
          pending.add(controller.switchVideo(releaseItem('reentrant')));
        }
      });
      addTearDown(subscription.cancel);
      controller.isSeeking.value = true;
      final initial = controller.switchVideo(releaseItem('second'));
      pending.add(initial);
      await until(() => native.disposeStarted.contains(1));
      expect(fired, isTrue);
      for (var n = 0; n < 30; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      final latest = controller.switchVideo(releaseItem('latest'));
      pending.add(latest);
      for (var n = 0; n < 30; n++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(native.nextId, 1);
      native.disposeGates[1]!.complete();
      await Future.wait(pending);
      expect(native.nextId, 2);
      expect(controller.video.value?.id, 'active-latest');
    },
  );
}
