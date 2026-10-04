import 'package:get/get.dart';

import '../../data/sources/video_source.dart';
import 'search_controller.dart';

class SearchBinding extends Bindings {
  @override
  void dependencies() {
    Get.lazyPut<SearchController>(
      () => SearchController(Get.find<VideoSource>()),
      fenix: true,
    );
  }
}
