/// PornHub 登录与用户会话服务。
///
/// ## 登录端点（已实测确认，2026-10-02）
///
/// 登录表单 `form.js-loginForm` 没有 `action`，端点藏在页面内联脚本里。实测取得：
///
/// ```
/// GET  /login                 -> 初始 Cookie + 隐藏域 token / redirect
/// POST /front/authenticate    -> {"success":"1","username":"...","avatar":"..."}
/// ```
///
/// 请求体为表单编码：`email` / `password` / `token` / `redirect` / `from`。
/// **实测该流程可用**，且未触发 reCAPTCHA（登录页虽带 reCAPTCHA site key，
/// 但它是风险触发式而非强制）。
///
/// 因此本服务提供两条登录路径，[login] 为主、[importCookies] 为兜底：
/// - [login]：账号密码原生登录，体验最好；
/// - [importCookies]：当官网启用风控（验证码/二次验证）导致原生登录失败时使用。
///
/// 会话有效性由 [verifySession] 判定，判据是「首页是否仍出现 `/login` 入口」——
/// 该判据已用真实登录会话验证过（登录后首页确实不再含该链接）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_logger.dart';

class PornHubAuthService extends GetxService {
  static PornHubAuthService get to => Get.find<PornHubAuthService>();

  static const String baseUrl = 'https://cn.pornhub.com';

  /// 实测取得的登录端点（来自登录页内联脚本的 `loginUrl` 字段）。
  static const String _loginPath = '/front/authenticate';

  static const String _prefCookieKey = 'pornhub_cookies';
  static const String _prefUsernameKey = 'pornhub_username';

  /// Changes before replacing credentials, including signing into the same user.
  final RxInt sessionRevision = 0.obs;
  final RxBool isLoggedIn = false.obs;
  final RxBool isVerifying = false.obs;
  final RxBool isLoggingIn = false.obs;
  final RxString username = ''.obs;

  /// 最近一次失败原因（供 UI 显示，而不是只写日志）。
  final RxString lastError = ''.obs;

  final Map<String, String> _cookies = <String, String>{};

  String get cookieHeader =>
      _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

  bool get hasCookies => _cookies.isNotEmpty;

  /// 当前登录用户名，由登录响应返回。
  String get userName => username.value;

  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  late final Dio _dio;

  Future<PornHubAuthService> init() async {
    _dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 20),
        headers: <String, String>{
          'User-Agent': defaultUserAgent,
          'Referer': '$baseUrl/',
          'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        },
        validateStatus: (status) => status != null && status < 500,
      ),
    );
    await _restoreSession();
    return this;
  }

  // ------------------------------------------------------------------ 原生登录

  /// 账号密码原生登录。
  ///
  /// 流程与实测一致：先 GET `/login` 取初始 Cookie 与隐藏域 `token`，
  /// 再 POST `/front/authenticate`。响应为 JSON，`success == "1"` 即成功。
  Future<bool> login(String email, String password) async {
    if (email.trim().isEmpty || password.isEmpty) {
      lastError.value = '账号或密码为空';
      return false;
    }
    await logout();
    isLoggingIn.value = true;
    lastError.value = '';
    try {
      AppLogger.i('PornHubAuth', '开始原生登录');

      // 1) 取初始 Cookie 与表单 token。
      final loginPage = await _dio.get<String>(
        '$baseUrl/login',
        options: Options(headers: <String, String>{'Referer': '$baseUrl/'}),
      );
      _mergeSetCookies(loginPage.headers['set-cookie']);

      final html = loginPage.data ?? '';
      final token = _hiddenInput(html, 'token');
      final redirect = _hiddenInput(html, 'redirect');
      if (token.isEmpty) {
        lastError.value = '未能取得登录令牌（官网页面结构可能已变更）';
        AppLogger.w('PornHubAuth', '登录页未找到 token 隐藏域');
        return false;
      }

      // 2) 提交凭据。
      final resp = await _dio.post<String>(
        '$baseUrl$_loginPath',
        data: <String, String>{
          'email': email.trim(),
          'password': password,
          'token': token,
          'redirect': redirect,
          'from': '',
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: <String, String>{
            'Referer': '$baseUrl/login',
            'X-Requested-With': 'XMLHttpRequest',
            'Cookie': cookieHeader,
          },
        ),
      );
      _mergeSetCookies(resp.headers['set-cookie']);

      final body = resp.data ?? '';
      final decoded = _tryDecodeJson(body);
      if (decoded == null) {
        lastError.value = '登录响应无法解析（可能被风控拦截，请改用 Cookie 导入）';
        AppLogger.w('PornHubAuth', '登录响应不是有效 JSON');
        return false;
      }

      final success = '${decoded['success']}' == '1';
      if (!success) {
        final message = decoded['message'];
        lastError.value = (message is String && message.isNotEmpty)
            ? message
            : '账号或密码不正确';
        AppLogger.w('PornHubAuth', '登录失败: ${lastError.value}');
        return false;
      }

      final name = decoded['username'];
      username.value = (name is String && name.isNotEmpty)
          ? name
          : 'PornHub 用户';
      isLoggedIn.value = true;
      await _saveSession();
      AppLogger.i('PornHubAuth', '登录成功');
      return true;
    } catch (e) {
      lastError.value = '登录异常: $e';
      AppLogger.w('PornHubAuth', '登录异常: $e');
      return false;
    } finally {
      isLoggingIn.value = false;
    }
  }

  /// 取 `<input name="x" value="y">` 的 value。属性顺序不固定，两种顺序都试。
  static String _hiddenInput(String html, String name) {
    final pattern = RegExp(
      '<input[^>]*name="${RegExp.escape(name)}"[^>]*value="([^"]*)"',
    );
    final first = pattern.firstMatch(html);
    if (first != null) return first.group(1) ?? '';
    final reversed = RegExp(
      '<input[^>]*value="([^"]*)"[^>]*name="${RegExp.escape(name)}"',
    );
    return reversed.firstMatch(html)?.group(1) ?? '';
  }

  static Map<String, dynamic>? _tryDecodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  // ------------------------------------------------------------------ Cookie 维护

  void _mergeSetCookies(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    for (final sc in setCookies) {
      final pair = sc.split(';').first.split('=');
      if (pair.length >= 2) {
        final key = pair[0].trim();
        final value = pair.sublist(1).join('=').trim();
        if (key.isNotEmpty) _cookies[key] = value;
      }
    }
  }

  /// 官网在响应里刷新 Cookie 时同步本地会话。
  void updateSessionCookies(List<String>? setCookies) {
    if (setCookies == null || setCookies.isEmpty) return;
    final previous = cookieHeader;
    _mergeSetCookies(setCookies);
    if (previous != cookieHeader) unawaited(_saveSession());
  }

  /// 导入浏览器 Cookie 串（`k=v; k2=v2`）。
  ///
  /// 导入后**必须**配合 [verifySession] 才能确认登录成功 —— 只看
  /// 「有没有 PHPSESSID」会把匿名会话误判为已登录。
  Future<bool> importCookies(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      lastError.value = 'Cookie 为空';
      return false;
    }
    await logout();
    for (final segment in trimmed.split(';')) {
      final pair = segment.trim().split('=');
      if (pair.length >= 2) {
        final key = pair[0].trim();
        if (key.isNotEmpty) {
          _cookies[key] = pair.sublist(1).join('=').trim();
        }
      }
    }
    if (_cookies.isEmpty) {
      lastError.value = 'Cookie 格式无法识别，应形如 name=value; name2=value2';
      return false;
    }
    await _saveSession();
    AppLogger.i('PornHubAuth', '已导入 ${_cookies.length} 条 Cookie，开始校验会话');
    return verifySession();
  }

  /// 发一次真实请求确认会话是否有效。
  ///
  /// 判据：登录态下首页不再出现「登录」入口。这比检查某个具体 Cookie 名稳健 ——
  /// 官网的会话 Cookie 名称与数量都可能变化。
  Future<bool> verifySession() async {
    if (_cookies.isEmpty) {
      isLoggedIn.value = false;
      return false;
    }
    final revision = sessionRevision.value;
    isVerifying.value = true;
    try {
      final resp = await _dio.get<String>(
        '$baseUrl/',
        options: Options(
          headers: <String, String>{
            'Referer': '$baseUrl/',
            'Cookie': cookieHeader,
          },
        ),
      );
      if (revision != sessionRevision.value) return false;
      final html = resp.data ?? '';
      if (html.isEmpty) {
        lastError.value = '会话校验失败：响应为空';
        isLoggedIn.value = false;
        return false;
      }
      // 未登录时首页一定包含指向 /login 的入口；已登录时会换成用户菜单。
      final hasLoginEntry =
          html.contains('href="/login') ||
          html.contains("href='/login") ||
          html.contains('/login?redirect=');
      if (!hasLoginEntry) {
        username.value = _extractUsername(html) ?? 'PornHub 用户';
      }
      isLoggedIn.value = !hasLoginEntry;
      lastError.value = isLoggedIn.value ? '' : '会话已失效，请重新导入 Cookie';

      if (isLoggedIn.value) {
        username.value = _extractUsername(html) ?? 'PornHub 用户';
        await _saveSession();
        AppLogger.i('PornHubAuth', '会话有效，已登录');
      } else {
        AppLogger.w('PornHubAuth', '会话校验未通过：页面仍存在登录入口');
      }
      return isLoggedIn.value;
    } catch (e) {
      if (revision != sessionRevision.value) return false;
      lastError.value = '会话校验异常: $e';
      AppLogger.w('PornHubAuth', '会话校验异常: $e');
      isLoggedIn.value = false;
      return false;
    } finally {
      if (revision == sessionRevision.value) isVerifying.value = false;
    }
  }

  /// 从首页 HTML 里取用户名。取不到返回 null（不编造）。
  static String? _extractUsername(String html) {
    // 已登录时页头会出现用户菜单链接，形如 href="/users/<name>"。
    final match = RegExp(r'href="/users/([A-Za-z0-9_\-]{2,40})"')
        .firstMatch(html);
    return match?.group(1);
  }

  Future<void> logout() async {
    sessionRevision.value++;
    isVerifying.value = false;
    _cookies.clear();
    isLoggedIn.value = false;
    username.value = '';
    lastError.value = '';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_prefCookieKey);
      await prefs.remove(_prefUsernameKey);
    } catch (e) {
      AppLogger.w('PornHubAuth', '清除本地会话异常: $e');
    }
    AppLogger.i('PornHubAuth', '已退出登录');
  }

  // ------------------------------------------------------------------ 持久化

  Future<void> _restoreSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefCookieKey);
      if (saved == null || saved.isEmpty) return;
      for (final segment in saved.split(';')) {
        final pair = segment.trim().split('=');
        if (pair.length >= 2) {
          _cookies[pair[0].trim()] = pair.sublist(1).join('=').trim();
        }
      }
      username.value = prefs.getString(_prefUsernameKey) ?? '';
      // 恢复时先按「有 Cookie」置为已登录，随后由 verifySession 校正。
      // 不做乐观置位的替代方案是每次启动都卡一次网络校验，代价更大。
      isLoggedIn.value = _cookies.isNotEmpty;
      AppLogger.i('PornHubAuth', '已恢复本地会话（${_cookies.length} 条 Cookie），待校验');
    } catch (e) {
      AppLogger.w('PornHubAuth', '恢复本地会话异常: $e');
    }
  }

  Future<void> _saveSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefCookieKey, cookieHeader);
      await prefs.setString(_prefUsernameKey, username.value);
    } catch (e) {
      AppLogger.w('PornHubAuth', '保存本地会话异常: $e');
    }
  }
}
