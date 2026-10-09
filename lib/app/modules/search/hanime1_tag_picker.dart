/// Hanime1 官网 `/search` 页「內容標籤」弹窗的 App 实现。
///
/// 官网原始结构（抓到的真实 HTML）：
/// ```
/// <div id="tags" class="modal" role="dialog">
///   <div class="modal-dialog">
///     <div class="modal-content">
///       <div class="modal-header">
///         <span class="material-icons modal-close-btn" data-dismiss="modal">close</span>
///         <h4 class="modal-title">內容標籤</h4>
///       </div>
///       <div class="modal-body" style="overflow-y:scroll; padding-top:0px;">
///         <div style="background-color:#323434; margin:0 -15px 20px -15px; padding:5px 15px 0 15px;">
///           <h5 style="font-weight:bold">廣泛配對
///             <label class="hentai-switch" style="float:right">
///               <input type="checkbox" name="broad" id="broad">
///               <span class="hentai-slider round"></span>
///             </label>
///           </h5>
///           <p style="color:gray; font-size:1.25rem; padding-right:60px">
///             較多結果，較不精準。配對所有包含任何一個選擇的標籤的影片，而非全部標籤。
///           </p>
///         </div>
///         <h5>影片屬性</h5>
///         <label class="hentai-tags-wrapper">
///           <input name="tags[]" type="checkbox" value="無碼">
///           <span class="checkmark">無碼</span>
///         </label>
///         … 共 7 组 240 项 …
///       </div>
///       <hr style="border-color:#323434; margin:0">
///       <div class="modal-footer">
///         <div data-dismiss="modal">取消</div>
///         <button type="submit">顯示搜索結果</button>
///       </div>
///     </div>
///   </div>
/// </div>
/// ```
///
/// 相关 CSS（`app.css`，官网 `html{font-size:10px}` 所以 `1rem = 10px`）：
/// ```
/// .modal-content      { background-color:#181817; border:1px solid #323434;
///                       border-radius:12px; color:#fff }
/// .modal-header       { height:65px; border-bottom:1px solid #333 }
/// .modal-header .modal-title        { text-align:center; font-weight:700; font-size:16px }
/// .modal-header .modal-close-btn    { position:absolute; top:15px; left:12px; font-size:18px }
/// .modal-body         { padding:15px; height:calc(100% - 129px); overflow-y:scroll }
/// .hentai-tags-wrapper{ margin:0 4px 8px 0 }
/// .checkmark          { height:32px; line-height:26px; padding:2px 12px;
///                       border:1px solid #323434; border-radius:30px; font-size:1.25rem }
/// .hentai-tags-wrapper input:checked ~ .checkmark { background-color:#dc143c }
/// .hentai-tags-wrapper:hover input ~ .checkmark   { background-color:#2c2d2c }
/// .hentai-switch      { width:33px; height:17px }
/// .hentai-slider      { background-color:#ccc }
/// .hentai-slider:before { width:19px; height:19px; left:-1px; bottom:-3px }
///   （选中态：track #dc143c，knob translateX(17px)）
/// .modal-footer div   { float:left; line-height:38px; color:#fff; text-decoration:underline }
/// .modal-footer button{ background-color:#323434; color:#fff; font-weight:700;
///                       border-radius:5px; padding:10px 20px }
/// ```
library;

import 'package:flutter/material.dart' hide SearchController;

import '../../core/app_theme.dart';

import '../../data/models/hanime1_models.dart';
import 'search_controller.dart';

// ---------------- 官方配色（`app.css`） ----------------
// .modal-content background-color
// .modal-content border / .checkmark border
// 「廣泛配對」通栏底 / 提交按钮底
// .checkmark 选中态

const Map<String, String> _tagTextSimplifications = <String, String>{
  '內容標籤': '内容标签',
  '廣泛配對': '广泛配对',
  '較多結果，較不精準。配對所有包含任何一個選擇的標籤的影片，而非全部標籤。': '更多结果，精确度较低。匹配包含所选任意一个标签的视频，而非全部标签。',
  '影片屬性': '影片属性',
  '人物關係': '人物关系',
  '角色設定': '角色设定',
  '無碼': '无码',
  'AI解碼': 'AI解码',
  '斷面圖': '断面图',
  '近親': '近亲',
  '女兒': '女儿',
  '師生': '师生',
  '青梅竹馬': '青梅竹马',
  '處女': '处女',
  '女教師': '女教师',
  '男教師': '男教师',
  '女醫生': '女医生',
  '女病人': '女病人',
  '護士': '护士',
  '大小姐': '大小姐',
  '女僕': '女仆',
  '巫女': '巫女',
  '風俗娘': '风俗娘',
  '女忍者': '女忍者',
  '女戰士': '女战士',
  '魔法少女': '魔法少女',
  '異時族': '异时族',
  '妖精': '妖精',
  '機械娘': '机械娘',
  '無口': '无口',
  '無表情': '无表情',
  '眼神死': '眼神死',
  '仿線': '仿线',
  '雙馬尾': '双马尾',
  '巨乳': '巨乳',
  '舌吻': '舌吻',
  '乳乳': '乳乳',
};

String _simplifiedTagText(String value) =>
    _tagTextSimplifications[value] ?? value;

/// 打开「內容標籤」弹窗。
Future<void> showHanime1TagPicker(
  BuildContext context,
  SearchController controller,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _Hanime1TagPickerSheet(controller: controller),
  );
}

class _Hanime1TagPickerSheet extends StatefulWidget {
  const _Hanime1TagPickerSheet({required this.controller});

  final SearchController controller;

  @override
  State<_Hanime1TagPickerSheet> createState() => _Hanime1TagPickerSheetState();
}

class _Hanime1TagPickerSheetState extends State<_Hanime1TagPickerSheet> {
  late final Set<String> _selected;
  late bool _broad;

  SearchController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _selected = controller.tagFilter.toSet();
    _broad = controller.tagBroad.value;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    // showModalBottomSheet(useSafeArea: true) 会给内容套一层 SafeArea，
    // 所以可用高度必须先扣掉上下安全区；直接按屏幕高度取比例会溢出。
    final available =
        media.size.height - media.padding.top - media.padding.bottom;

    return Container(
      height: available * 0.97,
      decoration: BoxDecoration(
        color: context.cSurface,
        borderRadius: BorderRadius.all(Radius.circular(8)),
        border: Border.fromBorderSide(BorderSide(color: context.cBorder)),
      ),
      child: Column(
        children: [
          _buildHeader(context),
          Expanded(child: _buildBody(context)),
          Divider(height: 1, thickness: 1, color: context.cBorder),
          _buildFooter(context),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- 顶部标题栏

  Widget _buildHeader(BuildContext context) {
    return SizedBox(
      // .modal-header { height:65px; border-bottom:1px solid #333 }
      height: 50,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.center,
            child: Text(
              '内容标签',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: context.cTextMain,
              ),
            ),
          ),
          Positioned(
            left: 12,
            top: 15,
            child: _CircleIconButton(
              icon: Icons.close,
              tooltip: '關閉',
              onTap: () => Navigator.of(context).pop(),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Divider(height: 1, thickness: 1, color: context.cBorder),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------------ 主体

  Widget _buildBody(BuildContext context) {
    // 官网 `.modal-body { padding:15px }`，而「廣泛配對」那条灰底用
    // `margin: 0 -15px 20px -15px` 把左右各外扩 15px，正好抵消 body 的 padding，
    // 于是变成通栏。这里不照搬负 margin（Flutter 里会被父级约束夹住），
    // 改成「滚动容器不设水平 padding，灰底通栏、分组各自内缩 15px」，
    // 渲染结果与官网一致。
    return SingleChildScrollView(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 「廣泛配對」通栏灰底
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 20),
            padding: const EdgeInsets.fromLTRB(15, 5, 15, 0),
            color: context.cSurfaceAlt,
            child: _buildBroadBlock(),
          ),

          // 各组标签
          Padding(
            padding: const EdgeInsets.fromLTRB(15, 0, 15, 15),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final group in hanime1TagGroups) _buildGroup(group),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 「廣泛配對」开关块。
  Widget _buildBroadBlock() {
    final broad = _broad;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '广泛配对',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: context.cTextMain,
              ),
            ),
            const Spacer(),
            _HentaiSwitch(
              value: broad,
              onChanged: (v) => setState(() => _broad = v),
            ),
          ],
        ),
        const SizedBox(height: 4),
        // 官网原文（p style="color:gray; font-size:1.25rem; padding-right:60px"）
        Padding(
          padding: EdgeInsets.only(right: 60, bottom: 12),
          child: Text(
            '更多结果，精确度较低。匹配包含所选任意一个标签的视频，而非全部标签。',
            style: TextStyle(
              fontSize: 12.5,
              color: context.cTextSub,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }

  /// 单个分组：`<h5>影片屬性</h5>` + 该组全部标签胶囊。
  Widget _buildGroup(Hanime1TagGroup group) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          // 官网 h5 style="margin-top:20px; margin-bottom:15px"
          padding: const EdgeInsets.only(top: 20, bottom: 15),
          child: Text(
            _simplifiedTagText(group.title),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: context.cTextMain,
            ),
          ),
        ),
        // 官网 `.hentai-tags-wrapper { margin:0 4px 8px 0 }`
        Wrap(
          spacing: 4,
          runSpacing: 8,
          children: [
            for (final tag in group.tags)
              _TagCheckPill(
                label: tag,
                checked: _selected.contains(tag),
                onTap: () => setState(() {
                  if (!_selected.add(tag)) _selected.remove(tag);
                }),
              ),
          ],
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 底部

  Widget _buildFooter(BuildContext context) {
    return Padding(
      // .modal-footer { padding:12px 15px; text-align:center }
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          // 「取消」—— 官网是左浮动带下划线的文字
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 5, vertical: 8),
              child: Text(
                '取消',
                style: TextStyle(
                  fontSize: 13,
                  color: context.cTextMain,
                  decoration: TextDecoration.underline,
                  decorationColor: context.cTextMain,
                ),
              ),
            ),
          ),
          const Spacer(),
          // 「顯示搜索結果」—— type=submit，提交表单
          SizedBox(
            height: 38,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: context.cSurfaceAlt,
                foregroundColor: context.cTextMain,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 20),
              ),
              onPressed: () {
                Navigator.of(context).pop();
                controller.applyTagSelection(
                  _selected.toList(growable: false),
                  _broad,
                );
              },
              child: Text(
                '显示搜索结果',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单个标签胶囊（官网 `label.hentai-tags-wrapper > span.checkmark`）。
class _TagCheckPill extends StatelessWidget {
  const _TagCheckPill({
    required this.label,
    required this.checked,
    required this.onTap,
  });

  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        // .checkmark { height:32px; line-height:26px; padding:2px 12px; border-radius:30px }
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: checked ? context.cAccent : Colors.transparent,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: context.cBorder),
        ),
        child: Text(
          _simplifiedTagText(label),
          style: TextStyle(
            fontSize: 12.5,
            color: context.cTextMain,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

/// 官网 `.hentai-switch`（33×17，选中 track 变 #dc143c，knob 右移 17px）。
class _HentaiSwitch extends StatelessWidget {
  const _HentaiSwitch({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: SizedBox(
        width: 33,
        height: 17,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              decoration: BoxDecoration(
                color: value ? context.cAccent : context.cTextSub,
                borderRadius: BorderRadius.circular(34),
              ),
            ),
            // knob: 19x19，未选中 left:-1，选中 translateX(17px)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 200),
              left: value ? 17 : -1,
              top: -1,
              child: Container(
                width: 19,
                height: 19,
                decoration: BoxDecoration(
                  color: context.cTextMain,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(color: Color(0x33000000), blurRadius: 1),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 官网 `.modal-close-btn`：圆形热区 + `close` 图标。
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    // 官网 `.modal-close-btn` 是个 28px 的圆（18px 图标 + 5px 内边距），
    // hover 时底色变 #323434。InkWell + CircleBorder 就是等价效果。
    final button = InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Icon(icon, size: 18, color: context.cTextMain),
      ),
    );

    if (tooltip == null || tooltip!.isEmpty) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}
