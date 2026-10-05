/// “动态”板块控制器：
/// 负责汇聚所有已关注 UP 主的作品，并支持：
/// 1. 按发布时间从新到旧严格排序；
/// 2. 每页 24 个视频，支持页码翻页；
/// 3. 顶部切换查看“全部关注”或单个 UP 主；
/// 4. 监听关注变动实时自动刷新。
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/app_logger.dart';
import '../../data/models/video_item.dart';
import '../../data/sources/video_source.dart';
import '../../services/preload_service.dart';
import '../../services/user_service.dart';

class FeedController extends GetxController {
  static final _secondsAgoRe = RegExp(r'(\d+)\s*秒前');
  static final _minutesAgoRe = RegExp(r'(\d+)\s*分钟前');
  static final _hoursAgoRe = RegExp(r'(\d+)\s*小时前');
  static final _daysAgoRe = RegExp(r'(\d+)\s*天前');
  static final _weeksAgoRe = RegExp(r'(\d+)\s*(?:周|个星期)前');
  static final _monthsAgoRe = RegExp(r'(\d+)\s*(?:个?月)前');
  static final _yearsAgoRe = RegExp(r'(\d+)\s*年前');
  static final _absoluteDateRe = RegExp(r'(\d{4}-\d{1,2}-\d{1,2})');

  static const int pageSize = 24;

  final VideoSource _source =
      SourceRegistry.byId('site91') ?? Get.find<VideoSource>();
  final UserService _userSvc = Get.find<UserService>();

  final ScrollController scrollController = ScrollController();

  /// 当前选中的 UP 主（'ALL' 代表全部关注 UP 主聚合流）
  final RxString selectedAuthor = 'ALL'.obs;

  /// 加载状态与错误
  final RxBool isLoading = false.obs;
  final RxnString error = RxnString();

  /// 分页信息
  final RxInt currentPage = 1.obs;
  final RxInt totalPages = 1.obs;
  final RxInt totalCount = 0.obs;

  /// 当前页展示的 24 个视频
  final RxList<VideoItem> displayVideos = <VideoItem>[].obs;

  /// 内存中已拉取聚合排序的全部视频池（按时间从新到旧排好）
  final List<VideoItem> _aggregatedPool = <VideoItem>[];
  final Set<String> _seenVideoIds = <String>{};

  /// 每个作者已拉取到的网站底层页码：author -> fetchedPage
  final Map<String, int> _authorFetchedPages = <String, int>{};

  int _request = 0;
  Worker? _subscriptionsWorker;

  @override
  void onInit() {
    super.onInit();
    // 监听关注列表变动，发生变化时重置刷新
    _subscriptionsWorker = ever(_userSvc.subscriptions, (_) {
      if (!isClosed) {
        loadData(reset: true);
      }
    });
  }

  @override
  void onReady() {
    super.onReady();
    loadData(reset: true);
  }

  @override
  void onClose() {
    _request++;
    _subscriptionsWorker?.dispose();
    scrollController.dispose();
    super.onClose();
  }

  List<String> get subscriptions => _userSvc.subscriptions.toList();

  /// 切换筛选的 UP 主
  void selectAuthor(String author) {
    if (selectedAuthor.value == author) return;
    selectedAuthor.value = author;
    loadData(reset: true);
  }

  /// 重新加载或初次加载
  Future<void> loadData({bool reset = false}) async {
    if (isClosed || (!reset && isLoading.value)) return;
    final request = ++_request;
    if (subscriptions.isEmpty) {
      isLoading.value = false;
      error.value = null;
      displayVideos.clear();
      _aggregatedPool.clear();
      _seenVideoIds.clear();
      totalPages.value = 1;
      totalCount.value = 0;
      currentPage.value = 1;
      return;
    }

    if (reset) {
      currentPage.value = 1;
      _aggregatedPool.clear();
      _seenVideoIds.clear();
      _authorFetchedPages.clear();
    }

    isLoading.value = true;
    error.value = null;

    try {
      final currentTargetAuthor = selectedAuthor.value;
      if (currentTargetAuthor != 'ALL') {
        // 单个 UP 主作品模式
        await _fetchSingleAuthorMore(currentTargetAuthor, request);
      } else {
        // 全部关注 UP 主聚合流模式
        await _fetchAggregatedMore(request);
      }

      if (isClosed || request != _request) return;
      _updateDisplayPage();
    } catch (e, stack) {
      if (isClosed || request != _request) return;
      AppLogger.e('FeedController', '加载动态视频失败: $e', e, stack);
      error.value = '加载动态失败: $e';
    } finally {
      if (!isClosed && request == _request) isLoading.value = false;
    }
  }

  /// 上一页
  void previousPage() {
    if (isClosed || isLoading.value) return;
    final request = _request;
    if (currentPage.value > 1) {
      currentPage.value--;
      if (isClosed || request != _request) return;
      _updateDisplayPage();
      _scrollToTop();
    }
  }

  /// 下一页
  Future<void> nextPage() async {
    if (isClosed || isLoading.value) return;
    final request = _request;
    if (currentPage.value < totalPages.value) {
      currentPage.value++;
      // 如果当前内存池中的条目不足下一页的 24 条，尝试补充拉取
      final neededCount = currentPage.value * pageSize;
      if (_aggregatedPool.length < neededCount) {
        isLoading.value = true;
        try {
          if (selectedAuthor.value == 'ALL') {
            await _fetchAggregatedMore(request);
          } else {
            await _fetchSingleAuthorMore(selectedAuthor.value, request);
          }
        } finally {
          if (!isClosed && request == _request) isLoading.value = false;
        }
      }
      if (isClosed || request != _request) return;
      _updateDisplayPage();
      _scrollToTop();
    }
  }

  /// 跳转至指定页
  Future<void> goToPage(int target) async {
    if (isClosed || isLoading.value) return;
    final request = _request;
    if (target < 1 ||
        target > totalPages.value ||
        target == currentPage.value) {
      return;
    }
    currentPage.value = target;
    final neededCount = currentPage.value * pageSize;
    if (_aggregatedPool.length < neededCount) {
      isLoading.value = true;
      try {
        if (selectedAuthor.value == 'ALL') {
          await _fetchAggregatedMore(request);
        } else {
          await _fetchSingleAuthorMore(selectedAuthor.value, request);
        }
      } finally {
        if (!isClosed && request == _request) isLoading.value = false;
      }
    }
    if (isClosed || request != _request) return;
    _updateDisplayPage();
    _scrollToTop();
  }

  void _scrollToTop() {
    if (scrollController.hasClients) {
      scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  /// 根据当前 currentPage 更新 displayVideos
  void _updateDisplayPage() {
    totalCount.value = _aggregatedPool.length;
    totalPages.value = max(1, (_aggregatedPool.length / pageSize).ceil());

    if (currentPage.value > totalPages.value) {
      currentPage.value = totalPages.value;
    }

    final start = (currentPage.value - 1) * pageSize;
    if (start >= _aggregatedPool.length) {
      displayVideos.clear();
      return;
    }
    final end = min(start + pageSize, _aggregatedPool.length);
    final pageItems = _aggregatedPool.sublist(start, end);
    displayVideos.assignAll(pageItems);
    PreloadService.instance.preloadList(pageItems);
  }

  /// 拉取全部关注作者的一批视频并合并排序
  Future<void> _fetchAggregatedMore(int request) async {
    final authors = subscriptions;
    if (authors.isEmpty) return;

    final List<Future<List<VideoItem>>> futures = [];

    for (final author in authors) {
      final nextPage = (_authorFetchedPages[author] ?? 0) + 1;
      futures.add(_fetchAuthorPage(author, nextPage));
    }

    final results = await Future.wait(futures);
    if (isClosed || request != _request) return;

    for (int i = 0; i < authors.length; i++) {
      final author = authors[i];
      final items = results[i];
      if (items.isNotEmpty) {
        _authorFetchedPages[author] = (_authorFetchedPages[author] ?? 0) + 1;
        for (final item in items) {
          if (_seenVideoIds.add(item.id)) {
            _aggregatedPool.add(item);
          }
        }
      }
    }

    // 核心要求：按照时间排序，新的在前
    _sortAggregatedPool();
  }

  /// 拉取单个作者的视频
  Future<void> _fetchSingleAuthorMore(String author, int request) async {
    // 每次拉取 2 页以凑足 24 个视频
    for (int k = 0; k < 2; k++) {
      final nextPage = (_authorFetchedPages[author] ?? 0) + 1;
      final items = await _fetchAuthorPage(author, nextPage);
      if (isClosed || request != _request) return;
      if (items.isEmpty) break;

      _authorFetchedPages[author] = nextPage;
      for (final item in items) {
        if (_seenVideoIds.add(item.id)) {
          _aggregatedPool.add(item);
        }
      }
    }

    _sortAggregatedPool();
  }

  void _sortAggregatedPool() {
    final now = DateTime.now();
    final dates = {
      for (final item in _aggregatedPool)
        item: parsePublishedDate(item.publishedAt, reference: now),
    };
    _aggregatedPool.sort((a, b) => dates[b]!.compareTo(dates[a]!));
  }

  Future<List<VideoItem>> _fetchAuthorPage(String author, int page) async {
    try {
      final res = await _source.search(
        query: SearchQuery(keyword: author, searchType: SearchType.authorId),
        page: page,
        pageSize: pageSize,
      );
      return res.items;
    } catch (e) {
      AppLogger.w('FeedController', '拉取作者 [$author] 第 $page 页失败: $e');
      return const <VideoItem>[];
    }
  }

  /// 智能解析相对时间/绝对日期格式，返回 DateTime 以便精确排序（新的在前）
  static DateTime parsePublishedDate(String? raw, {DateTime? reference}) {
    if (raw == null || raw.trim().isEmpty) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    final str = raw.trim();
    final now = reference ?? DateTime.now();

    if (str.contains('刚刚')) return now;

    // 秒前
    final secMatch = _secondsAgoRe.firstMatch(str);
    if (secMatch != null) {
      final s = int.tryParse(secMatch.group(1)!) ?? 0;
      return now.subtract(Duration(seconds: s));
    }

    // 分钟前
    final minMatch = _minutesAgoRe.firstMatch(str);
    if (minMatch != null) {
      final m = int.tryParse(minMatch.group(1)!) ?? 0;
      return now.subtract(Duration(minutes: m));
    }

    // 小时前
    final hrMatch = _hoursAgoRe.firstMatch(str);
    if (hrMatch != null) {
      final h = int.tryParse(hrMatch.group(1)!) ?? 0;
      return now.subtract(Duration(hours: h));
    }

    // 昨天 / 前天
    if (str.contains('昨天')) {
      return now.subtract(const Duration(days: 1));
    }
    if (str.contains('前天')) {
      return now.subtract(const Duration(days: 2));
    }

    // 天前
    final dayMatch = _daysAgoRe.firstMatch(str);
    if (dayMatch != null) {
      final d = int.tryParse(dayMatch.group(1)!) ?? 0;
      return now.subtract(Duration(days: d));
    }

    // 周前
    final wkMatch = _weeksAgoRe.firstMatch(str);
    if (wkMatch != null) {
      final w = int.tryParse(wkMatch.group(1)!) ?? 0;
      return now.subtract(Duration(days: w * 7));
    }

    // 月前
    final moMatch = _monthsAgoRe.firstMatch(str);
    if (moMatch != null) {
      final mo = int.tryParse(moMatch.group(1)!) ?? 0;
      return now.subtract(Duration(days: mo * 30));
    }

    // 年前
    final yrMatch = _yearsAgoRe.firstMatch(str);
    if (yrMatch != null) {
      final y = int.tryParse(yrMatch.group(1)!) ?? 0;
      return now.subtract(Duration(days: y * 365));
    }

    // 绝对日期：2026-03-14 或 2026/03/14 或 2026.03.14
    final cleanDate = str.replaceAll('/', '-').replaceAll('.', '-');
    final parsed = DateTime.tryParse(cleanDate);
    if (parsed != null) return parsed;

    final dateMatch = _absoluteDateRe.firstMatch(cleanDate);
    if (dateMatch != null) {
      final subParsed = DateTime.tryParse(dateMatch.group(1)!);
      if (subParsed != null) return subParsed;
    }

    return DateTime.fromMillisecondsSinceEpoch(0);
  }
}
