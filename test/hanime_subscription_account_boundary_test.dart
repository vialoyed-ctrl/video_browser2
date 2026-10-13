import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:video_browser/app/modules/hanime1/hanime1_controller.dart';
import 'package:video_browser/app/services/hanime1_auth_service.dart';
import 'package:video_browser/app/services/preload_service.dart';

import 'support/hanime_list_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'switch',
    'logout',
    'published',
    'lateError',
    'anonymous',
    'emailSwitch',
    'emailLogout',
    'nameSwitch',
    'nameLogout',
  ]) {
    test('subscription account boundary $mode', () async {
      Get.testMode = true;
      final previousPreload = PreloadService.instance.preloadCount.value;
      PreloadService.instance.preloadCount.value = 0;
      final auth = Get.put(Hanime1AuthService());
      auth.userId.value =
          mode == 'anonymous' ||
              mode.startsWith('email') ||
              mode.startsWith('name')
          ? ''
          : 'fixture-account-A';
      if (mode.startsWith('email')) {
        auth.userEmail.value = 'fixture-A@example.invalid';
      }
      if (mode.startsWith('name')) auth.username.value = 'fixture-A';
      auth.isLoggedIn.value = mode != 'anonymous';
      final source = HanimeListFixture();
      final c = Get.put(Hanime1Controller(source));
      try {
        c.subscriptionSort.value = 'popular';
        c.subscriptionGenre.value = 'fixture-genre';
        c.subscriptionDate.value = 'fixture-date';
        c.subscriptionDuration.value = 'fixture-duration';
        c.subscriptionTags.assignAll(['fixture-tag']);
        c.subscriptionBroad.value = true;
        final old = c.loadSubscriptions();
        expect(source.subRequests.length, 1);
        if (mode == 'published') {
          source.subRequests[0].complete(
            fixtureSubscriptions('old-account', 3),
          );
          await old;
        }
        if (mode != 'anonymous' && mode != 'lateError') {
          c.selectedCreator.value = 'previous-account-creator';
          c.subscriptionsError.value = 'previous-account-error';
        }
        if (mode == 'logout' || mode.endsWith('Logout')) {
          auth.isLoggedIn.value = false;
        } else if (mode == 'emailSwitch') {
          auth.userEmail.value = 'fixture-B@example.invalid';
        } else if (mode == 'nameSwitch') {
          auth.username.value = 'fixture-B';
        } else if (mode != 'anonymous') {
          auth.userId.value = 'fixture-account-B';
        }
        if (mode == 'lateError') {
          final current = c.loadSubscriptions();
          source.subRequests[0].completeError(StateError('old-account-error'));
          await old;
          expect(
            c.isLoadingSub.value,
            true,
            reason: 'Old cleanup cannot end the new request',
          );
          expect(c.subscriptionsError.value, isNull);
          source.subRequests[1].complete(
            fixtureSubscriptions('new-account', 1),
          );
          await current;
          expect(c.subVideos.first.id, 'new-account-0');
        } else if (mode != 'published') {
          source.subRequests[0].complete(
            fixtureSubscriptions('old-account', 1),
          );
          await old;
        }
        if (mode == 'anonymous') {
          expect(c.subVideos.first.id, 'old-account-0');
        } else if (mode != 'lateError') {
          expect(
            c.subVideos,
            isEmpty,
            reason: 'Previous-account content must not survive account change',
          );
          expect(c.subData.value, isNull);
          expect(c.isLoadingSub.value, false);
          expect(c.subscriptionsPage.value, 1);
          expect(c.subscriptionsTotalPages.value, 1);
          expect(c.selectedCreator.value, isNull);
          expect(c.subscriptionsError.value, isNull);
        }
        expect(
          c.subscriptionSort.value,
          'popular',
          reason: 'Account cleanup preserves site filters',
        );
        expect(c.subscriptionGenre.value, 'fixture-genre');
        expect(c.subscriptionDate.value, 'fixture-date');
        expect(c.subscriptionDuration.value, 'fixture-duration');
        expect(c.subscriptionTags, ['fixture-tag']);
        expect(c.subscriptionBroad.value, true);
      } finally {
        Get.reset();
        PreloadService.instance.preloadCount.value = previousPreload;
      }
    });
  }
  test('closed subscription controller releases auth listeners', () async {
    Get.testMode = true;
    final previousPreload = PreloadService.instance.preloadCount.value;
    PreloadService.instance.preloadCount.value = 0;
    final auth = Get.put(Hanime1AuthService());
    auth.userId.value = 'fixture-A';
    auth.isLoggedIn.value = true;
    final source = HanimeListFixture();
    final c = Get.put(Hanime1Controller(source));
    try {
      final pending = c.loadSubscriptions();
      source.subRequests.single.complete(fixtureSubscriptions('published', 1));
      await pending;
      await Get.delete<Hanime1Controller>();
      expect(c.isClosed, true);
      auth.userEmail.value = 'fixture-B@example.invalid';
      expect(
        c.subVideos.map((x) => x.id),
        fixtureCards('published').map((x) => x.id),
        reason: 'Disposed account worker must no longer mutate closed state',
      );
    } finally {
      Get.reset();
      PreloadService.instance.preloadCount.value = previousPreload;
    }
  });
}
