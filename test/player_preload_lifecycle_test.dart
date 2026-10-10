import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/services/player_service.dart';

// Only the native boundary is replaced. PlayerService and Flutter's real
// VideoPlayerController still own initialization, subscriptions and disposal.
class _NativePlayers extends VideoPlayerPlatform {
  final active = <int>{};
  final released = <int>[];
  final subscriptionsCanceled = <int>[];
  final events = <int, StreamController<VideoEvent>>{};
  final failPauseFor = <int>{};
  final heldPauseFor = <int, Completer<void>>{};
  bool autoInitialize = true;
  final firstListenerReady = Completer<void>();
  final firstCreationStarted = Completer<void>();
  Completer<void>? creationGate;
  int nextId = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    final id = ++nextId;
    if (!firstCreationStarted.isCompleted) firstCreationStarted.complete();
    await creationGate?.future;
    active.add(id);
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    // The Android implementation rejects events for an already released ID.
    if (!active.contains(playerId)) throw StateError('Player already released');
    final stream = StreamController<VideoEvent>(
      onCancel: () => subscriptionsCanceled.add(playerId),
    );
    events[playerId] = stream;
    if (!firstListenerReady.isCompleted) firstListenerReady.complete();
    if (autoInitialize) initializePlayer(playerId);
    return stream.stream;
  }

  void initializePlayer(int playerId) {
    events[playerId]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(minutes: 2),
        size: const Size(640, 360),
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {
    active.remove(playerId);
    released.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    if (failPauseFor.contains(playerId)) {
      throw PlatformException(code: 'pause_failed');
    }
    final held = heldPauseFor[playerId];
    if (held != null) await held.future;
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  Future<void> closeStreams() async {
    for (final stream in events.values) {
      await stream.close();
    }
  }
}

VideoItem _item(String id) => VideoItem(
  id: 'lifecycle-$id',
  title: 'Lifecycle fixture',
  author: '',
  detailUrl: 'https://example.invalid/$id',
  hlsUrl: 'https://example.invalid/$id.mp4',
);

Future<void> _drainCleanup() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final service = PlayerService.instance;
  late VideoPlayerPlatform previous;
  late _NativePlayers native;

  setUp(() {
    previous = VideoPlayerPlatform.instance;
    native = _NativePlayers();
    VideoPlayerPlatform.instance = native;
    service.clearPreplay();
  });

  tearDown(() async {
    if (native.creationGate != null && !native.creationGate!.isCompleted) {
      native.creationGate!.complete();
    }
    for (final gate in native.heldPauseFor.values) {
      if (!gate.isCompleted) gate.complete();
    }
    native.failPauseFor.clear();
    service.clearPreplay();
    await _drainCleanup();
    await native.closeStreams();
    VideoPlayerPlatform.instance = previous;
  });

  for (final operation in ['clear', 'replace']) {
    test(
      '$operation disposes warm player despite an unresponsive pause',
      () async {
        await service.preOpen(_item('held-old'));
        final gate = Completer<void>();
        native.heldPauseFor[1] = gate;
        try {
          if (operation == 'clear') {
            service.clearPreplay();
          } else {
            await service.preOpen(_item('held-new'));
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          expect(
            native.released,
            contains(1),
            reason: 'An unanswered pause must not block disposing a paused warm instance',
          );
          expect(native.subscriptionsCanceled, contains(1));
          expect(native.active, operation == 'clear' ? isEmpty : {2});
          expect(
            service.currentOpeningItem?.id,
            operation == 'clear' ? null : _item('held-new').id,
          );
        } finally {
          if (!gate.isCompleted) gate.complete();
          await _drainCleanup();
        }
      },
    );
  }
  test(
    'clear releases the native player and listener even when pause fails',
    () async {
      await service.preOpen(_item('clear'));
      expect(native.active, {1});
      native.failPauseFor.add(1);

      service.clearPreplay();
      await _drainCleanup();

      expect(service.currentOpeningItem, isNull);
      expect(
        native.active,
        isEmpty,
        reason: 'native resources must outlive neither the warm slot nor its listener',
      );
      expect(native.released, [1]);
      expect(native.subscriptionsCanceled, [1]);
    },
  );

  test(
    'replacing a warm player releases the old one after a pause failure',
    () async {
      await service.preOpen(_item('old'));
      native.failPauseFor.add(1);
      final replacement = _item('new');

      await service.preOpen(replacement);
      await _drainCleanup();

      expect(native.active, {2});
      expect(native.released, [1]);
      expect(native.subscriptionsCanceled, [1]);
      expect(service.isPreplaying(replacement), isTrue);
    },
  );

  test('repeated clears release a normal warm player exactly once', () async {
    await service.preOpen(_item('normal'));
    service.clearPreplay();
    service.clearPreplay();
    await _drainCleanup();
    expect(native.active, isEmpty);
    expect(native.released, [1]);
    expect(native.subscriptionsCanceled, [1]);
  });

  test('clearing the warm slot does not release a controller already taken by a player', () async {
    final item = _item('take');
    await service.preOpen(item);
    final taken = service.takePreloadedController(item);
    expect(taken, isNotNull);
    expect(taken!.value.isInitialized, isTrue);
    service.clearPreplay();
    await _drainCleanup();
    expect(native.active, {1});
    expect(native.released, isEmpty);
    await taken.dispose();
    expect(native.active, isEmpty);
  });

  test(
    'canceling before initialized settles preOpen without a native ready event',
    () async {
      native.autoInitialize = false;
      final opening = service.preOpen(_item('pending-clear'));
      await native.firstListenerReady.future;

      service.clearPreplay();
      await _drainCleanup();

      expect(native.active, isEmpty);
      expect(native.subscriptionsCanceled, [1]);
      await expectLater(
        opening.timeout(const Duration(milliseconds: 100)),
        completes,
      );
    },
  );

  test('replacing a pending warm player settles the old task and preserves the new slot', () async {
    native.autoInitialize = false;
    final oldOpening = service.preOpen(_item('pending-old'));
    await native.firstListenerReady.future;
    native.autoInitialize = true;
    final replacement = _item('pending-new');

    await service.preOpen(replacement);
    await _drainCleanup();

    expect(native.active, {2});
    expect(native.subscriptionsCanceled, [1]);
    expect(service.isPreplaying(replacement), isTrue);
    await expectLater(
      oldOpening.timeout(const Duration(milliseconds: 100)),
      completes,
    );
  });

  test('taking a pending warm controller settles service work but leaves initialization to its owner', () async {
    native.autoInitialize = false;
    final item = _item('pending-take');
    final opening = service.preOpen(item);
    await native.firstListenerReady.future;

    final taken = service.takePreloadedController(item);
    expect(taken, isNotNull);
    try {
      service.clearPreplay();
      await _drainCleanup();
      expect(native.active, {1});
      expect(native.subscriptionsCanceled, isEmpty);
      expect(taken!.value.isInitialized, isFalse);
      await expectLater(
        opening.timeout(const Duration(milliseconds: 100)),
        completes,
      );
      native.initializePlayer(1);
      await _drainCleanup();
      expect(taken.value.isInitialized, isTrue);
    } finally {
      await taken!.dispose();
    }
  });

  test('repeated touch of the same pending item keeps its initialization and ownership', () async {
    native.autoInitialize = false;
    final item = _item('pending-repeat');
    final opening = service.preOpen(item);
    await native.firstListenerReady.future;

    await service.preOpen(item);
    expect(native.active, {1});
    expect(native.released, isEmpty);
    native.initializePlayer(1);
    await opening;
    expect(service.isPreplaying(item), isTrue);
  });

  test(
    'native initialization failure clears only its owned warm controller',
    () async {
      native.autoInitialize = false;
      final opening = service.preOpen(_item('pending-error'));
      await native.firstListenerReady.future;

      native.events[1]!.addError(
        PlatformException(
          code: 'initialize_failed',
          message: 'Fixture failure',
        ),
      );
      await opening;
      await _drainCleanup();

      expect(native.active, isEmpty);
      expect(native.released, [1]);
      expect(native.subscriptionsCanceled, [1]);
      expect(service.currentOpeningItem, isNull);
    },
  );

  test('canceling during native creation settles service work and releases the late-created player', () async {
    final gate = Completer<void>();
    native.creationGate = gate;
    final opening = service.preOpen(_item('pending-create'));
    await native.firstCreationStarted.future;

    service.clearPreplay();
    try {
      await expectLater(
        opening.timeout(const Duration(milliseconds: 100)),
        completes,
      );
    } finally {
      gate.complete();
      await _drainCleanup();
    }
    expect(native.active, isEmpty);
    expect(native.released, [1]);
    expect(service.currentOpeningItem, isNull);
  });
}
