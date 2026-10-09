import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_browser/app/data/sources/site91_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('keeps only the requested fixed primary domain', () {
    expect(Site91Source.defaultDomains, <String>['https://www.91porny.com']);
  });

  test('migrates removed built-in mirrors to the primary domain', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'site91_custom_base_url': 'https://hsex.icu',
    });
    final source = Site91Source();

    expect(await source.restoreSelectedDomain(), isTrue);
    expect(source.currentBaseUrl, Site91Source.defaultDomains.first);
    expect(await source.loadCustomDomains(), <String>[
      'https://www.91tanhua189.sbs',
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('site91_custom_base_url'),
      Site91Source.defaultDomains.first,
    );
  });

  test('migrates the old primary hostname to the www hostname', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'site91_custom_base_url': 'https://91porny.com',
    });
    final source = Site91Source();

    expect(await source.restoreSelectedDomain(), isTrue);
    expect(source.currentBaseUrl, 'https://www.91porny.com');
    expect(await source.loadCustomDomains(), <String>[
      'https://www.91tanhua189.sbs',
    ]);
  });

  test('migrates the former mirror to a removable custom domain', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'site91_custom_base_url': 'https://www.91tanhua189.sbs',
    });
    final source = Site91Source();

    expect(await source.restoreSelectedDomain(), isTrue);
    expect(source.currentBaseUrl, 'https://www.91tanhua189.sbs');
    expect(await source.loadCustomDomains(), <String>[
      'https://www.91tanhua189.sbs',
    ]);

    await source.saveDomainConfiguration(
      Site91Source.defaultDomains.single,
      customDomains: const <String>[],
    );
    expect(await Site91Source().loadCustomDomains(), isEmpty);
  });

  test(
    'persists user-added domains and removes them from the saved list',
    () async {
      final source = Site91Source();
      await source.saveDomainConfiguration(
        'https://mirror.example/',
        customDomains: <String>[
          'mirror.example',
          'https://www.91porny.com',
          'https://mirror.example/',
        ],
      );

      expect(source.currentBaseUrl, 'https://mirror.example');
      expect(await source.loadCustomDomains(), <String>[
        'https://mirror.example',
      ]);

      await source.saveDomainConfiguration(
        Site91Source.defaultDomains.first,
        customDomains: const <String>[],
      );
      final restoredSource = Site91Source();
      expect(await restoredSource.restoreSelectedDomain(), isTrue);
      expect(restoredSource.currentBaseUrl, Site91Source.defaultDomains.first);
      expect(await restoredSource.loadCustomDomains(), isEmpty);
    },
  );

  test('rejects custom domain entries that include a path or query', () {
    expect(Site91Source.normalizeDomain('example.com/path'), isEmpty);
    expect(Site91Source.normalizeDomain('example.com?mirror=1'), isEmpty);
    expect(
      Site91Source.normalizeDomain(' WWW.Example.com/ '),
      'https://www.example.com',
    );
    expect(
      Site91Source.normalizeDomain('HTTPS://WWW.Example.com/'),
      'https://www.example.com',
    );
  });
}
