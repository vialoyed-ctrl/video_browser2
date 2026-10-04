/// Hanime1 登录与用户会话服务。
///
/// 极简纯 Dart 原生实现（使用已有 Dio + SharedPreferences，零冗余组件）：
/// 1. 自动提取 CSRF Token；
/// 2. 模拟 POST 登录，持久化已鉴权 Session Cookies；
/// 3. 管理登录态 (isLoggedIn)、用户名 (username)、用户 UID (userId)；
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_logger.dart';

class Hanime1AuthService extends GetxService {
  static Hanime1AuthService get to => Get.find<Hanime1AuthService>();

  static const String _prefCookieKey = 'hanime1_cookies';
  static const String _prefUsernameKey = 'hanime1_username';
  static const String _prefUserIdKey = 'hanime1_user_id';
  static const String _prefEmailKey = 'hanime1_email';

  final RxBool isLoggedIn = false.obs;
  final RxString username = ''.obs;
  final RxString userId = ''.obs;
  final RxString userEmail = ''.obs;
  final RxBool isLoggingIn = false.obs;

  final Map<String, String> _cookies = <String, String>{};

  String get cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  late final Dio _dio;

  Future<Hanime1AuthService> init() async {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'Referer': 'https://hanime1.me/',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );

    await _restoreSession();
    return this;
  }

  void _mergeSetCookies(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    for (final sc in setCookies) {
      final pair = sc.split(';').first.split('=');
      if (pair.length >= 2) {
        final k = pair[0].trim();
        final v = pair.sublist(1).join('=').trim();
        if (k.isNotEmpty) {
          _cookies[k] = v;
        }
      }
    }
  }

  /// Keep the persisted login session in sync with cookies refreshed by the site.
  void updateSessionCookies(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final previous = cookieHeader;
    _mergeSetCookies(setCookies);
    if (previous != cookieHeader) unawaited(_saveSession());
  }

  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCookies = prefs.getString(_prefCookieKey);
      final savedUser = prefs.getString(_prefUsernameKey);
      final savedUid = prefs.getString(_prefUserIdKey);
      final savedMail = prefs.getString(_prefEmailKey);

      if (savedCookies != null && savedCookies.isNotEmpty) {
        for (final pairStr in savedCookies.split(';')) {
          final pair = pairStr.split('=');
          if (pair.length >= 2) {
            _cookies[pair[0].trim()] = pair.sublist(1).join('=').trim();
          }
        }
      }

      if (_cookies.containsKey('hanime1_session') ||
          _cookies.keys.any((k) => k.startsWith('remember_web'))) {
        isLoggedIn.value = true;
        username.value = savedUser ?? 'Hanime1 用户';
        userId.value = savedUid ?? '';
        userEmail.value = savedMail ?? '';
        AppLogger.i(
          'Hanime1Auth',
          '已恢复 Hanime1 登录会话: ${username.value} (UID: ${userId.value})',
        );
      }
    } catch (e) {
      AppLogger.w('Hanime1Auth', '恢复本地登录凭据异常: $e');
    }
  }

  Future<void> _saveSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefCookieKey, cookieHeader);
      await prefs.setString(_prefUsernameKey, username.value);
      await prefs.setString(_prefUserIdKey, userId.value);
      await prefs.setString(_prefEmailKey, userEmail.value);
    } catch (e) {
      AppLogger.w('Hanime1Auth', '保存本地登录凭据异常: $e');
    }
  }

  /// 账号密码原生极速登录
  Future<bool> login(String email, String password) async {
    isLoggingIn.value = true;
    try {
      AppLogger.i('Hanime1Auth', '开始登录 Hanime1');

      // 1. GET /login 提取 CSRF Token 与初始 Cookie
      final getResp = await _dio.get<String>(
        'https://hanime1.me/login',
        options: Options(headers: {'Referer': 'https://hanime1.me/'}),
      );

      _mergeSetCookies(getResp.headers['set-cookie']);

      final html = getResp.data ?? '';
      final doc = html_parser.parse(html);
      final tokenInput = doc.querySelector('input[name="_token"]');
      final csrfToken = tokenInput?.attributes['value'] ?? '';

      if (csrfToken.isEmpty) {
        AppLogger.e('Hanime1Auth', '未能提取到 CSRF Token');
        return false;
      }

      // 2. POST /login 提交凭证
      final postResp = await _dio.post<String>(
        'https://hanime1.me/login',
        data: {
          '_token': csrfToken,
          'email': email.trim(),
          'password': password,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: {
            'Cookie': cookieHeader,
            'Referer': 'https://hanime1.me/login',
          },
          followRedirects: false,
        ),
      );

      _mergeSetCookies(postResp.headers['set-cookie']);

      // 检查登录后 Cookie 是否包含已鉴权 Session
      final hasSession =
          _cookies.containsKey('hanime1_session') ||
          _cookies.keys.any((k) => k.startsWith('remember_web'));
      if (!hasSession) {
        AppLogger.w('Hanime1Auth', '登录失败：未收到有效鉴权 Cookie');
        return false;
      }

      // 3. 验证并提取用户资料
      final checkResp = await _dio.get<String>(
        'https://hanime1.me/subscriptions',
        options: Options(
          headers: {'Cookie': cookieHeader, 'Referer': 'https://hanime1.me/'},
        ),
      );

      _mergeSetCookies(checkResp.headers['set-cookie']);

      final checkHtml = checkResp.data ?? '';
      final checkDoc = html_parser.parse(checkHtml);

      // 从页面寻找 /user/{id} 链接
      String parsedUid = '';
      for (final a in checkDoc.querySelectorAll('a[href*="/user/"]')) {
        final href = a.attributes['href'] ?? '';
        final m = RegExp(r'/user/(\d+)').firstMatch(href);
        if (m != null) {
          parsedUid = m.group(1)!;
          break;
        }
      }

      String parsedName = 'Hanime1 用户';
      if (parsedUid.isNotEmpty) {
        // 请求个人中心获取真实昵称
        final userResp = await _dio.get<String>(
          'https://hanime1.me/user/$parsedUid',
          options: Options(
            headers: {'Cookie': cookieHeader, 'Referer': 'https://hanime1.me/'},
          ),
        );
        final userDoc = html_parser.parse(userResp.data ?? '');
        final h1 = userDoc.querySelector('h1');
        if (h1 != null && h1.text.trim().isNotEmpty) {
          parsedName = h1.text.trim();
        }
      }

      userEmail.value = email.trim();
      userId.value = parsedUid;
      username.value = parsedName;
      isLoggedIn.value = true;

      await _saveSession();
      AppLogger.i('Hanime1Auth', '登录成功');
      return true;
    } catch (e, stack) {
      AppLogger.e('Hanime1Auth', '登录异常: $e', e, stack);
      return false;
    } finally {
      isLoggingIn.value = false;
    }
  }

  /// 退出登录
  Future<void> logout() async {
    _cookies.clear();
    isLoggedIn.value = false;
    username.value = '';
    userId.value = '';
    userEmail.value = '';

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefCookieKey);
    await prefs.remove(_prefUsernameKey);
    await prefs.remove(_prefUserIdKey);
    await prefs.remove(_prefEmailKey);

    AppLogger.i('Hanime1Auth', '已退出登录');
  }
}
