import 'package:flutter/material.dart';

import '../services/grid_layout_settings.dart';
import 'app_toast.dart';

class GridLayoutSettingsTile extends StatelessWidget {
  const GridLayoutSettingsTile({super.key, this.settings});
  final GridLayoutSettings? settings;

  @override
  Widget build(BuildContext context) {
    final model = settings ?? GridLayoutSettings.instance;
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => ListTile(
        leading: const Icon(Icons.view_module_outlined),
        title: const Text('卡片布局'),
        subtitle: Text(
          model.columns == 0 ? '自动适配屏幕 · 所有页面' : '${model.columns}列 · 所有页面',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('视频卡片列数'),
            children: [
              for (var count = 0; count <= 6; count++)
                SimpleDialogOption(
                  onPressed: () async {
                    Navigator.pop(context);
                    try {
                      await model.setColumns(count);
                    } catch (_) {
                      AppToast.show('布局已应用，但保存失败，请重试');
                    }
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(count == 0 ? '自动（适配手机和平板）' : '$count列'),
                      ),
                      if (model.columns == count)
                        const Icon(Icons.check_rounded),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
