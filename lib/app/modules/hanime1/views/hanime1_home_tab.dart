/// Hanime1 专属移动端首页 Tab (主页)。
///
/// 严格还原截图 1 视觉：
/// 1. 顶部分类胶囊横滑栏 (里番、泡面番、Motion Anime、3DCG、2.5D...)；
/// 2. Hero 焦点大卡片（还得是人妻 2 / Alice : The Witch's Trial）；
/// 3. 多栏目视频列表（最新上市、最新上传、里番...）与【更多 >】按钮；
/// 4. 双列瀑布网格视频卡片。
library;

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/app_theme.dart';
import '../../../data/models/hanime1_models.dart';
import '../../../routes/app_navigator.dart';
import '../hanime1_controller.dart';
import '../widgets/hanime1_card.dart';
import '../widgets/hanime1_hero_card.dart';

class Hanime1HomeTab extends StatefulWidget {
  const Hanime1HomeTab({super.key});

  @override
  State<Hanime1HomeTab> createState() => _Hanime1HomeTabState();
}

class _Hanime1HomeTabState extends State<Hanime1HomeTab> {
  @override
  void initState() {
    super.initState();
    // 首页数据的加载时机放在这里，而**不是** `Hanime1Controller.onInit`。
    //
    // 原因：`RootBinding.dependencies()` 会在**两个版面**都无条件
    // `Get.put<Hanime1Controller>`（见 root_binding.dart），而 onInit 里一加载
    // 就是整页 hanime1 首页 + 连带触发的整页预加载。真机日志实测：91 版面启动时
    // `[Hanime1Source] 拉取首页结构化数据` 与 `[Site91] 正在获取频道` 同时在跑，
    // 等于白烧一份流量和一轮解析。
    //
    // 本 Tab 只在 hanime1 版面被构建（root_view 按版面分支），
    // 所以这里才是「用户真的要看 hanime1 首页」的准确时机。
    final ctrl = Hanime1Controller.to;
    if (ctrl.homeData.value == null) {
      ctrl.loadHomeData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = Hanime1Controller.to;

    return Obx(() {
      if (ctrl.isLoadingHome.value && ctrl.homeData.value == null) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(
                strokeWidth: 2.5,
                color: context.cAccent,
              ),
              const SizedBox(height: 14),
              Text(
                '正在加载 Hanime1 首页内容...',
                style: TextStyle(fontSize: 13, color: context.cTextSub),
              ),
            ],
          ),
        );
      }

      final error = ctrl.homeError.value;
      if (error != null && ctrl.homeData.value == null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.wifi_off_rounded,
                  size: 48,
                  color: context.cTextFaint,
                ),
                const SizedBox(height: 12),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: context.cTextSub),
                ),
                const SizedBox(height: 16),
                FilledButton.tonal(
                  onPressed: ctrl.loadHomeData,
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        );
      }

      final data = ctrl.homeData.value;
      if (data == null) {
        return const SizedBox.shrink();
      }

      return RefreshIndicator(
        color: context.cAccent,
        onRefresh: ctrl.loadHomeData,
        // 必须用 CustomScrollView + slivers，不能写成
        //   ListView(children: [...data.sections.map((s) => _buildSection(s))])
        // 且每个 section 内部再套 GridView.builder(shrinkWrap: true)。
        //
        // 那种写法有两个致命问题，叠加后首页会卡死：
        //   1. ListView(children:) 会一次性构建全部子项，没有懒加载；
        //   2. 嵌套的 shrinkWrap: true 会强制 GridView 在布局阶段测量并构建
        //      自己的全部子项。
        // 首页实测有 144 张卡片（12 个板块 × 12），于是首帧要同时构建 144 个
        // 卡片 widget、并发 144 个图片请求 —— 这是「特别卡」的主因之一。
        // 改成 sliver 后由 viewport 按需构建，只有可见的卡片会被 inflate。
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          slivers: [
            // 1. 顶部横滑分类胶囊条 (里番、泡面番、Motion Anime、3DCG、2.5D...)
            if (data.genreTabs.isNotEmpty)
              SliverToBoxAdapter(
                child: _buildGenreCapsules(context, data.genreTabs),
              ),

            // 2. Hero 焦点大卡片 (还得是人妻 2)
            if (data.hero != null)
              SliverToBoxAdapter(child: Hanime1HeroCard(hero: data.hero!)),

            // 3. 多栏目视频流 (最新上市、最新上傳、裏番...)
            for (final sec in data.sections)
              ..._buildSectionSlivers(context, sec),

            // 底部留白（原 ListView 的 padding.bottom）
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      );
    });
  }

  /// 顶部横向滚动分类胶囊栏
  Widget _buildGenreCapsules(BuildContext context, List<String> genres) {
    final genreValues =
        Hanime1Controller.to.homeData.value?.genreValues ??
        const <String, String>{};
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: genres.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (ctx, index) {
          final genre = genres[index];
          return InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () {
              final value = genreValues[genre];
              if (value != null) AppNavigator.toSearch(category: value);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: context.cSurfaceAlt,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: context.cBorder, width: 0.8),
              ),
              child: Text(
                genre,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: context.cTextMain,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 视频栏目板块（标题 + 【更多 >】+ 双列卡片网格）—— 返回 sliver 列表。
  ///
  /// 拆成「标题 sliver + 网格 sliver」两段，是为了让卡片网格成为真正的
  /// sliver：它只按需构建可见的卡片，而不是像原来那样一次性构建全部。
  ///
  /// 网格间距用官网移动端断点的 `gap: 17px 7px` 与 `padding: 0 7px`
  /// （见 [Hanime1VideoGridSliver]）。
  List<Widget> _buildSectionSlivers(
    BuildContext context,
    Hanime1Section section,
  ) {
    final title = section.title;
    final items = section.items;

    return [
      // 栏目标题与【更多 >】按钮
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.3,
                  ),
                ),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    final morePath = section.morePath;
                    final query = Uri.tryParse(morePath)?.queryParameters;
                    if (query != null && query.containsKey('sort')) {
                      final sort = query['sort'] ?? title;
                      final ctrl = Hanime1Controller.to;
                      final rankIdx = ctrl.rankingTabs.indexOf(sort);
                      if (rankIdx >= 0) {
                        ctrl.selectRankingTab(rankIdx);
                        ctrl.switchTab(1); // 切换到底部排行 Tab
                        return;
                      }
                    }
                    final genre = query?['genre'];
                    if (genre != null && genre.isNotEmpty) {
                      AppNavigator.toSearch(category: genre);
                    } else {
                      AppNavigator.toSearch(keyword: title);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 3.5,
                    ),
                    decoration: BoxDecoration(
                      color: context.cSurfaceAlt,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: context.cBorder, width: 0.8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '更多',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: context.cTextSub,
                          ),
                        ),
                        const SizedBox(width: 2),
                        Icon(
                          Icons.chevron_right,
                          size: 14,
                          color: context.cTextSub,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      const SliverToBoxAdapter(child: SizedBox(height: 6)),

      // 2 列网格展示该板块视频（懒构建）
      //
      // 用 [Hanime1VideoGridSliver] 而不是 SliverGrid：官网 `.horizontal-row`
      // 是 CSS grid，行高内容自适应（`align-items:stretch`），而 SliverGrid 必须
      // 给固定 childAspectRatio —— 卡片标题改成官方的**单行**截断后，比例算不准
      // 就会出现溢出条纹。逐行两个 Expanded 则完全没有这个问题。
      Hanime1VideoGridSliver(items: items),

      // 板块间距（原 Padding.bottom:8）
      const SliverToBoxAdapter(child: SizedBox(height: 8)),
    ];
  }
}
