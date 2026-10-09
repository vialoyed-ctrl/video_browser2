import 'package:flutter_test/flutter_test.dart';
import 'package:video_browser/app/modules/player/player_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('double-tap seek and playback actions preserve hidden controls', () {
    final controller = PlayerController();
    controller.showControls.value = false;

    controller.seekBy(10, revealControls: false);
    expect(controller.showControls.value, isFalse);

    controller.seekBy(-5, revealControls: false);
    expect(controller.showControls.value, isFalse);

    controller.togglePlay(revealControls: false);
    expect(controller.showControls.value, isFalse);
  });
}
