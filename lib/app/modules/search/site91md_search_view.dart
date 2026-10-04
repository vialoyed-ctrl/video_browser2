import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/responsive_utils.dart';
import '../../data/sources/video_source.dart';
import '../../routes/app_navigator.dart';
import '../../services/download_service.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/bili_video_card.dart';
import '../../widgets/append_pagination_footer.dart';
import 'site91md_search_controller.dart';

class Site91MdSearchView extends StatefulWidget {
  const Site91MdSearchView({
    super.key,
    required this.source,
    this.initialKeyword = '',
  });
  final VideoSource source;
  final String initialKeyword;
  @override
  State<Site91MdSearchView> createState() => _Site91MdSearchViewState();
}

class _Site91MdSearchViewState extends State<Site91MdSearchView> {
  late final Site91MdSearchController controller;
  late final TextEditingController input;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    controller = Site91MdSearchController(widget.source);
    input = TextEditingController(text: widget.initialKeyword);
    if (input.text.trim().isNotEmpty) controller.submit(input.text);
  }

  @override
  void dispose() {
    controller.dispose();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (scroll.hasClients) scroll.jumpTo(0);
    await controller.submit(input.text);
  }

  Future<void> _page(int page) async {
    await controller.goToPage(page);
    if (mounted && controller.error == null && scroll.hasClients) {
      scroll.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: input,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            hintText: '搜索 91md 官网视频',
            border: InputBorder.none,
            suffixIcon: IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.close),
              onPressed: () {
                input.clear();
                controller.submit('');
              },
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: _submit,
          ),
        ],
      ),
      body: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => CustomScrollView(
          controller: scroll,
          slivers: [
            if (!controller.searched)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('输入关键词，搜索官网视频')),
              )
            else ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    '搜索：${controller.keyword} · ${controller.firstPage == controller.page ? '第 ${controller.page} 页' : '第 ${controller.firstPage}–${controller.page} 页'} · ${controller.items.length} 条',
                  ),
                ),
              ),
              if (controller.loading)
                const SliverToBoxAdapter(child: LinearProgressIndicator()),
              if (controller.items.isEmpty &&
                  !controller.loading &&
                  controller.error == null)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('官网没有匹配的结果')),
                ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = ResponsiveLayout.gridColumnCount(
                      constraints.crossAxisExtent,
                    );
                    final width =
                        (constraints.crossAxisExtent - (columns - 1) * 6) /
                        columns;
                    return SliverGrid(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 6,
                        childAspectRatio: ResponsiveLayout.cardAspectRatio(
                          width,
                        ),
                      ),
                      delegate: SliverChildBuilderDelegate((context, index) {
                        final video = controller.items[index];
                        return BiliVideoCardV(
                          video: video,
                          onTap: () => AppNavigator.toPlayer(video),
                          onDownload: () {
                            Get.find<DownloadService>().enqueue(video);
                            AppToast.show('已加入下载队列');
                          },
                        );
                      }, childCount: controller.items.length),
                    );
                  },
                ),
              ),
              SliverToBoxAdapter(
                child: AppendPaginationFooter(
                  page: controller.page,
                  hasMore: controller.hasMore,
                  loading: controller.loading || controller.loadingMore,
                  error: controller.error,
                  onJump: _page,
                  onNext: controller.error != null
                      ? controller.retry
                      : controller.loadMore,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
