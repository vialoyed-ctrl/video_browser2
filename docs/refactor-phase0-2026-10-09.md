# P0：交接核对与回滚基线

日期：2026-10-09；项目：`E:\projects\video_browser2`。

## 已执行

- 完整阅读 `CODEX_HANDOFF.md` 与 `docs/refactor-audit-2026-10-09.md`。
- 对原始快照与当前源码做差异及 SHA-256 核对。排除构建缓存和本地 SDK 配置后，仅有交接记录中的两处生产文件变更及新增 `test/download_badge_count_test.dart`。原始快照只读保留。
- 保存 248 个源码/配置文件的 SHA-256 清单于 `work/handoff-validation/baseline-sha256.json`，差异清单在同目录 `snapshot-delta.txt`。这是接手时生成的清单，不能替代快照创建时的原始校验值。
- 建立本地 Git 基线 `3649739a8c0e5990f0c65d40f7485f32f7629406`，标签 `handoff-2026-10-09`；工作分支 `refactor/profile-ui-20261009`。未配置远程、未推送。
- 按明确文件清单跟踪 263 个文件；排除账号本地配置、签名密钥、缓存、APK、日志、截图、本地副本。构建所需 Gradle wrapper 三件均已跟踪，并补充忽略规则的明确例外。
- Superpowers 独立只读审查未发现凭据/产物误入基线或必要构建源码遗漏。审查未从全新检出目录构建，不能据此宣称无缓存可复现构建。

## 接手基线验证

| 验证 | 结果 |
|---|---|
| `flutter test --no-pub --reporter expanded` | 141 通过、1 跳过；exit 0 |
| `flutter analyze lib test --no-pub` | 0 error、0 warning，原有 7 条 `avoid_print` info；exit 1 |
| Android Profile ARM64 构建 | 成功；未改变版本文件，临时使用 `--build-number=2003` |
| 真机安装 | PMB110，`BUPR8HWKLZTCHAPN`；`adb install -r` 成功，域名设置恢复，首页加载 |

手机原安装包为 2.0.1 / versionCode 2002，已备份在 `work/handoff-validation/device-before-profile.apk`。未卸载应用，未清除应用数据。Profile 模式需要以 `enable-dart-profiling=true` 启动后连接 Flutter VM 服务。

## 本阶段范围与回滚

P0 没有再次修改下载角标，也没有修改生产 Dart、站点解析或播放器逻辑。原始快照保持在 `E:\projects\_video_browser2_refactor_backup_20261009`。

后续每个修复独立提交，优先使用 `git revert <修复提交>` 回滚。不要全目录覆盖，不要用清除手机数据来解决安装问题。设备安装包回滚与源码回滚是两件事；旧版本降级可能受 Android 限制，本轮没有执行降级或卸载。

详细原始日志放在忽略跟踪的 `work/handoff-validation/`；P1/P2 进展见 `docs/refactor-progress-2026-10-09.md`。
