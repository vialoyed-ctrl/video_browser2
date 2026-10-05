import 'package:get/get.dart';

import '../../data/sources/video_source.dart';
import 'search_controller.dart';

class SearchBinding extends Bindings {
  @override
  void dependencies() {
    if (SourceRegistry.defaultSource.id == 'site91md') return;
    // Each route captures the currently selected source, never an old fenix instance.
    if (Get.isRegistered<SearchController>()) {
      Get.delete<SearchController>(force: true);
    }
    Get.lazyPut<SearchController>(
      () => SearchController(SourceRegistry.defaultSource),
      fenix: true,
    );
  }
}
