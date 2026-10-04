/// Hanime1 专属移动端排行榜 Tab (本日排行)。
///
/// 功能特点：
/// 1. 顶部周期切换（本日排行、本周排行、本月排行、最新上市、最新上传）；
/// 2. 双列卡片网格；
/// 3. 下拉刷新与触底分页加载。
library;

import '../../../widgets/retained_page_sliver.dart';

import 'package:flutter/material.dart';

import '../../../widgets/pull_to_next_page.dart';

import 'package:get/get.dart';

import '../../../core/app_theme.dart';
import '../hanime1_controller.dart';
import '../widgets/hanime1_card.dart';
import '../widgets/hanime1_pagination.dart';

class Hanime1RankingTab extends StatefulWidget {
  const Hanime1RankingTab({super.key});

  @override
  State<Hanime1RankingTab> createState() => _Hanime1RankingTabState();
}

class _Hanime1RankingTabState extends State<Hanime1RankingTab> {
  @override
  Widget build(BuildContext context) {
    final ctrl = Hanime1Controller.to;

    return Column(
      children: [
        // 顶部排行榜标签切换栏
        Obx(() {
          final currentIdx = ctrl.currentRankTabIndex.value;
          return Container(
            height: 44,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: ctrl.rankingTabs.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (ctx, idx) {
                final tabName = ctrl.rankingTabs[idx];
                final isSelected = currentIdx == idx;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => ctrl.selectRankingTab(idx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 6,
                    ),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: isSelected ? context.cAccent : context.cSurfaceAlt,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isSelected ? context.cAccent : context.cBorder,
                        width: 0.8,
                      ),
                    ),
                    child: Text(
                      tabName,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: isSelected
                            ? FontWeight.bold
                            : FontWeight.w500,
                        // 选中是强调色底 → onPrimary；未选中是次级面 → 主文字色。
                        color: isSelected
                            ? context.scheme.onPrimary
                            : context.cTextMain,
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        }),

        const Divider(height: 1, thickness: 0.6),

        // 视频内容网格列表
        Expanded(
          child: Obx(() {
            if (ctrl.isLoadingRanking.value && ctrl.rankingVideos.isEmpty) {
              return Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: context.cAccent,
                ),
              );
            }

            if (ctrl.rankingVideos.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 48,
                      color: context.cTextFaint,
                    ),
                    const SizedBox(height: 12),
                    Text('暂无相关榜单条目', style: TextStyle(color: context.cTextSub)),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () => ctrl.loadRanking(
                        ctrl.rankingTabs[ctrl.currentRankTabIndex.value],
                      ),
                      child: const Text('重试刷新'),
                    ),
                  ],
                ),
              );
            }

            return RefreshIndicator(
              color: context.cAccent,
              onRefresh: () => ctrl.loadRanking(
                ctrl.rankingTabs[ctrl.currentRankTabIndex.value],
              ),
              // 与官网一致：`.horizontal-row` 是 2 列 CSS grid（行高内容自适应），
              // 所以用 Hanime1VideoGridSliver 而不是 GridView + 固定 childAspectRatio。
              child: PullToNextPage(
                hasNext: ctrl.hasMoreRanking.value,
                isLoading: ctrl.isLoadingRanking.value,
                onNext: ctrl.loadMoreRanking,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(
                    parent: BouncingScrollPhysics(),
                  ),
                  slivers: [
                    const SliverToBoxAdapter(child: SizedBox(height: 12)),
                    RetainedPageSliver(
                      key: ValueKey(ctrl.currentRankTabIndex.value),
                      items: List.of(
                        ctrl.rankingVideos.toList(growable: false),
                      ),
                      page: ctrl.rankingPage.value,
                      footer: Hanime1Pagination(
                        currentPage: ctrl.rankingPage.value,
                        onNext: ctrl.loadMoreRanking,
                        hasNext: ctrl.hasMoreRanking.value,
                        error: ctrl.rankingError.value,
                        totalPages: ctrl.rankingTotalPages.value,
                        isLoading: ctrl.isLoadingRanking.value,
                        onPageChanged: (page) => ctrl.loadRanking(
                          ctrl.rankingTabs[ctrl.currentRankTabIndex.value],
                          page: page,
                        ),
                      ),
                      gridBuilder: (pageItems) => Hanime1VideoGridSliver(
                        items: pageItems,
                        padding: const EdgeInsets.fromLTRB(
                          Hanime1CardH.horizontalPadding,
                          0,
                          Hanime1CardH.horizontalPadding,
                          24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}
