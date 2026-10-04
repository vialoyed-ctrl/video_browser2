import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/data/models/video_item.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';
import 'package:video_browser/app/data/sources/video_source.dart';
import 'package:video_browser/app/modules/home/home_controller.dart';

class _HomeSource extends Site91Source {
  final requests = <Completer<VideoPage>>[];

  @override
  Future<VideoPage> fetchChannelPage({
    required ChannelType channel,
    String? categoryPath,
    required int page,
    int pageSize = 12,
  }) {
    final request = Completer<VideoPage>();
    requests.add(request);
    return request.future;
  }
}

VideoPage _page(String id) => VideoPage(
  items: [VideoItem(id: id, title: id, author: '', hlsUrl: '')],
  page: 1,
  hasMore: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a quick channel switch shows the latest page and ignores the old reply',
    () async {
      final source = _HomeSource();
      final controller = HomeController(source);
      controller.onInit();
      expect(source.requests, hasLength(1));
      controller.switchChannel(
        ChannelType.video,
        const VideoCategory(id: 'new', name: 'New', path: '/video/new'),
      );
      expect(source.requests, hasLength(2));

      source.requests[1].complete(_page('new-channel'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.videos.single.id, 'new-channel');
      expect(controller.loadingFirst.value, isFalse);

      source.requests[0].complete(_page('stale-home'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.videos.single.id, 'new-channel');
      controller.onClose();
    },
  );
}
