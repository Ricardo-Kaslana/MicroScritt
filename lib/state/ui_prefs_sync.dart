/// UI 偏好回写:把角色布局、牌堆进度与侧栏折叠快照同步到 `ui-prefs.json`。
///
/// 偏好文件整体写入,任一字段的写点都必须走这里,避免只带自己的字段而把
/// 其它偏好重置;文件 provider 为空(测试/未注入)时跳过,写失败只打日志。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/ui_prefs.dart';
import 'providers.dart';

/// 把当前全部 UI 偏好快照写回 `ui-prefs.json`。
Future<void> syncUiPrefsFile(WidgetRef ref) async {
  final file = ref.read(uiPrefsFileProvider);
  if (file == null) return;
  await file.write(
    UiPrefs(
      characterLayout: ref.read(characterLayoutProvider),
      sidebarCollapsed: ref.read(sidebarCollapsedProvider),
      deckFrontCharacterId: ref.read(deckFrontCharacterIdProvider),
    ),
  );
}
