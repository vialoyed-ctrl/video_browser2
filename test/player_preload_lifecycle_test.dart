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
  int nextId = 0;

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
      onCancel: () => subscriptionsCanceled.add(playerId),
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
  Future<void> dispose(int playerId) async {
    active.remove(playerId);
    released.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    if (failPauseFor.contains(playerId)) {
      throw PlatformException(code: 'pause_failed');
    }
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
    native.failPauseFor.clear();
    service.clearPreplay();
    await _drainCleanup();
    await native.closeStreams();
    VideoPlayerPlatform.instance = previous;
  });

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
}
