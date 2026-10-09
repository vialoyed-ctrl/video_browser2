/// 应用入口。
library;

import 'dart:ui' show PlatformDispatcher;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app/core/app_theme.dart';
import 'app/core/app_scroll_behavior.dart';
import 'app/data/sources/hanime1_source.dart';
import 'app/data/sources/pornhub_source.dart';
import 'app/data/sources/site91_source.dart';
import 'app/data/sources/site91md_source.dart';
import 'app/data/sources/video_source.dart';
import 'app/routes/app_pages.dart';
import 'app/routes/app_routes.dart';
import 'app/services/download_service.dart';
import 'app/services/hanime1_auth_service.dart';
import 'app/services/hls_cache_proxy.dart';
import 'app/core/app_logger.dart';
import 'app/services/player_service.dart';
import 'app/services/pornhub_auth_service.dart';
import 'app/services/preload_service.dart';
import 'app/services/user_service.dart';
import 'app/widgets/app_toast.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initialize();

  // 杜绝 Release 模式下未捕获 UI 异常渲染全局灰屏方块 (RenderErrorBox)
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.e(
      'FlutterError',
      '全局捕获 Flutter 异常: ${details.exception}',
      details.exception,
      details.stack,
    );
  };
  ErrorWidget.builder = (FlutterErrorDetails details) {
    AppLogger.e(
      'ErrorWidget',
      '全局拦截 Widget 渲染崩溃: ${details.exception}',
      details.exception,
      details.stack,
    );
    return Container(color: Colors.black);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    AppLogger.e('PlatformDispatcher', '未处理的异步异常', error, stack);
    return true;
  };

  DateTime? lastSlowFrameLog;
  WidgetsBinding.instance.addTimingsCallback((frames) {
    for (final frame in frames) {
      final slowest = frame.buildDuration > frame.rasterDuration
          ? frame.buildDuration
          : frame.rasterDuration;
      if (slowest < const Duration(milliseconds: 500)) continue;
      final now = DateTime.now();
      if (lastSlowFrameLog != null &&
          now.difference(lastSlowFrameLog!) < const Duration(seconds: 2)) {
        continue;
      }
      lastSlowFrameLog = now;
      AppLogger.w(
        'FrameMonitor',
        '检测到慢帧：build=${frame.buildDuration.inMilliseconds}ms，'
            'raster=${frame.rasterDuration.inMilliseconds}ms',
      );
    }
  });

  // 精简内存占用：限制全局图片缓存数量与字节数，防止瀑布流无限滚动导致内存膨胀
  PaintingBinding.instance.imageCache.maximumSize = 100;
  PaintingBinding.instance.imageCache.maximumSizeBytes =
      40 * 1024 * 1024; // 40MB

  // 注册在线内容源。
  //
  // 刻意**不预设** baseUrl：内容域名由用户在启动引导里显式选择（见 RootView）。
  // 「谁先探测通过就用谁」的结果取决于当时的网络环境，在用户手机上并不可靠。
  final site91 = Site91Source();
  SourceRegistry.register(site91);

  final hanime1Auth = Hanime1AuthService();
  await hanime1Auth.init();
  Get.put<Hanime1AuthService>(hanime1Auth, permanent: true);

  final hanime1 = Hanime1Source();
  SourceRegistry.register(hanime1);

  // PornHub 内容源。
  //
  // 登录服务先于源注册就绪：源在发请求时要读 Cookie，若认证服务尚未 put 进容器，
  // 每次请求都会走 catch 分支退回未登录态（表现为「登录了却仍是游客视角」）。
  final pornHubAuth = PornHubAuthService();
  await pornHubAuth.init();
  Get.put<PornHubAuthService>(pornHubAuth, permanent: true);

  final pornHub = PornHubSource();
  SourceRegistry.register(pornHub);

  // 91麻豆（苹果CMS）内容源。本地账号：无登录，收藏/历史走本地存储。
  // 主站固定保留，镜像站由用户在「选择内容域名」里自行增删。
  final site91md = Site91MdSource();
  SourceRegistry.register(site91md);

  Get.put<VideoSource>(SourceRegistry.defaultSource, permanent: true);

  final downloadService = DownloadService();
  await downloadService.init();
  Get.put<DownloadService>(downloadService, permanent: true);

  final userService = UserService();
  await userService.init();
  Get.put<UserService>(userService, permanent: true);

  // 域名变更的处理必须挂在 userService 就绪之后 —— 它要重写已保存条目里的旧域名 URL。
  // 时机赶得上：真正的域名恢复/选择发生在 RootView 首帧之后，晚于这里。
  site91.onDomainChanged = (from, to, automatic) {
    // 1. 观看记录 / 稍后再看 / 收藏里存的是保存当时的绝对 URL。
    //    域名一变旧 host 就失效，不重写就会「点开播不了」。
    userService.rebaseVideoUrls(site91.rebaseUrl);
    // 2. 自动切换必须告知用户，否则他会以为自己选的域名仍在生效。
    if (automatic) {
      AppToast.show(
        '当前域名不可用，已自动切换到 ${to.replaceFirst(RegExp(r'^https?://'), '')}',
      );
    }
  };

  // 91麻豆 同样支持主站 + 镜像站切换，需要同一套「旧域名 URL 重写 + 自动切换提示」。
  site91md.onDomainChanged = (from, to, automatic) {
    userService.rebaseVideoUrls(site91md.rebaseUrl);
    if (automatic) {
      AppToast.show(
        '91麻豆 当前域名不可用，已自动切换到 ${to.replaceFirst(RegExp(r'^https?://'), '')}',
      );
    }
  };

  // 初始化视频预加载服务与本地极速代理引擎
  await PreloadService.instance.init();
  await HlsCacheProxy.instance.init();

  runApp(const VideoBrowserApp());

  // 首帧显示后立即在后台异步预热播放器硬件管线（零阻塞极速亮屏）
  WidgetsBinding.instance.addPostFrameCallback((_) {
    PlayerService.instance.init();
  });
}

class VideoBrowserApp extends StatelessWidget {
  const VideoBrowserApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 莫奈取色（Material You）：Android 12+ 从系统壁纸取色。
    // 其它平台（Windows / Android 12 以下）回调参数为 null，
    // 由 AppTheme 退回品牌种子色，仍是一套完整可用的 M3 配色。
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => GetMaterialApp(
        title: '播放仓库',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(dynamicScheme: lightDynamic),
        darkTheme: AppTheme.dark(dynamicScheme: darkDynamic),
        themeMode: ThemeMode.system,
        scrollBehavior: const AppScrollBehavior(),
        initialRoute: AppRoutes.root,
        getPages: AppPages.routes,
        defaultTransition: Transition.cupertino,
      ),
    );
  }
}
