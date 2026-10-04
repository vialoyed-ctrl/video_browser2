/// 兼容层：官网首页、搜索页、订阅页用的是**同一个**卡片组件
/// （`div.horizontal-card`），所以统一由 [Hanime1CardH] 实现。
///
/// 保留 `Hanime1Card` 这个名字，已有调用点（首页板块、排行榜、订阅页）无需改动。
/// typedef 对构造函数同样生效，所以 `Hanime1Card(video: v, onTap: ...)` 照旧可用。
///
/// 注意：`export` 只把名字**对外**导出，不会导入到本库作用域里，
/// 所以下面必须同时 `import` —— 否则 typedef 里的 `Hanime1CardH` 会报
/// `undefined_class`。
library;

import 'hanime1_card_h.dart';

export 'hanime1_card_h.dart';

typedef Hanime1Card = Hanime1CardH;
