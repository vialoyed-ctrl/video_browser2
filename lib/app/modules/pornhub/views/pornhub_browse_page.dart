import 'package:flutter/material.dart';

import 'pornhub_search_page.dart';
import 'pornhub_playlist_page.dart';

/// 直接保留官网分类、标签、片单链接及其查询参数。
class PornHubBrowsePage extends StatelessWidget {
  const PornHubBrowsePage({super.key, required this.title, required this.path});
  final String title;
  final String path;
  @override
  Widget build(BuildContext context) {
    final id = RegExp(r'^/playlist/(\d+)')
        .firstMatch(Uri.tryParse(path)?.path ?? '')
        ?.group(1);
    if (id != null) return PornHubPlaylistPage(id: id, title: title);
    return PornHubSearchPage(
      initialPath: path,
      title: title,
      initialKeyword: Uri.tryParse(path)?.queryParameters['search'] ?? '',
    );
  }
}
