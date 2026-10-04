import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/sources/hanime1_source.dart';
import 'package:video_browser/app/services/hanime1_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // 允许在测试中执行真实网络请求
  SharedPreferences.setMockInitialValues({});

  test('Hanime1 Auth and Scraping Integration Test', () async {
    // 1. Test Auth Service Login
    final auth = Hanime1AuthService();
    await auth.init();
    Get.put<Hanime1AuthService>(auth, permanent: true);

    final loginOk = await auth.login(
      Platform.environment['HANIME1_TEST_EMAIL']!,
      Platform.environment['HANIME1_TEST_PASSWORD']!,
    );
    expect(loginOk, isTrue, reason: 'Login with user credentials should succeed');
    expect(auth.isLoggedIn.value, isTrue);
    expect(auth.userId.value, isNotEmpty);
    print('✓ Auth Login OK: ${auth.username.value} (UID: ${auth.userId.value})');

    final source = Hanime1Source();

    // 2. Test Home Page Structured Data
    final homeData = await source.fetchHomeStructured();
    expect(homeData, isNotNull);
    expect(homeData!.genreTabs, isNotEmpty);
    expect(homeData.sections, isNotEmpty);
    print('✓ Home Structured OK: ${homeData.genreTabs.length} genres, ${homeData.sections.length} sections');
    if (homeData.hero != null) {
      print('✓ Hero Banner OK: "${homeData.hero!.title}" (${homeData.hero!.subtitle})');
    }

    final firstCard = homeData.sections.first.items.first;
    expect(firstCard.id, isNotEmpty);
    expect(firstCard.title, isNotEmpty);
    print('✓ Card Data OK: title="${firstCard.title}", duration="${firstCard.durationStr}", views="${firstCard.viewsStr}", author="${firstCard.author}"');

    // 3. Test Subscriptions Data
    final subData = await source.fetchSubscriptionsData();
    expect(subData.creators, isNotEmpty);
    expect(subData.items, isNotEmpty);
    print('✓ Subscriptions OK: ${subData.creators.length} creators, ${subData.items.length} videos');

    // 4. Test Ranking List
    final rankData = await source.fetchRankingList('本日排行');
    expect(rankData.items, isNotEmpty);
    print('✓ Ranking OK: ${rankData.items.length} ranking videos');

    // 5. Test Video Stream Detail
    final detail = await source.fetchDetail(firstCard.id);
    expect(detail, isNotNull);
    expect(detail!.variants, isNotEmpty);
    print('✓ Detail & Stream OK: ${detail.variants.length} quality variants (highest: ${detail.variants.first.label})');
  },
      skip: Platform.environment['HANIME1_TEST_EMAIL'] == null ||
          Platform.environment['HANIME1_TEST_PASSWORD'] == null,
      timeout: const Timeout(Duration(seconds: 45)));
}
