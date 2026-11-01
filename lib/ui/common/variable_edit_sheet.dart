import 'package:flutter/material.dart';
import '../../models/variable.dart';
import 'copy_button.dart';

/// 变量键值编辑结果:[key] 已 trim 且保证非空,[value] 已 trim(可为空串),
/// [access] 为保存到 `variables.agent_access` 的后台权限。
class VariableEditResult {
  final String key;
  final String value;
  final VariableAccess access;
  const VariableEditResult(this.key, this.value, this.access);
}

/// 变量键值编辑底单:新增与编辑共用。保存返回结果,取消返回 null。
///
/// [existingKeys] 传入**其它**已占用的键(编辑时不含当前这一条):输入命中时
/// 就地红字提示"保存将覆盖同名变量",但**不阻止保存** —— 覆盖是用户的显式选择。
/// 键为空(或仅空白)时保存键置灰:空键在 `variables` 表里没有意义。
Future<VariableEditResult?> showVariableEditSheet(
  BuildContext context, {
  required String title,
  String initialKey = '',
  String initialValue = '',
  VariableAccess initialAccess = VariableAccess.protected,
  Set<String> existingKeys = const {},
}) {
  return showModalBottomSheet<VariableEditResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _VariableEditSheet(
      title: title,
      initialKey: initialKey,
      initialValue: initialValue,
      initialAccess: initialAccess,
      existingKeys: existingKeys,
    ),
  );
}

class _VariableEditSheet extends StatefulWidget {
  final String title;
  final String initialKey;
  final String initialValue;
  final VariableAccess initialAccess;
  final Set<String> existingKeys;

  const _VariableEditSheet({
    required this.title,
    required this.initialKey,
    required this.initialValue,
    required this.initialAccess,
    required this.existingKeys,
  });

  @override
  State<_VariableEditSheet> createState() => _VariableEditSheetState();
}

class _VariableEditSheetState extends State<_VariableEditSheet> {
  /// 控制器由本 State 自建自养,底单关闭动画结束后随 dispose 释放
  /// (与 `text_edit_sheet.dart` 同一条约定,避免 use-after-dispose)。
  late final TextEditingController _keyController = TextEditingController(
    text: widget.initialKey,
  );
  late final TextEditingController _valueController = TextEditingController(
    text: widget.initialValue,
  );

  /// 当前键(驱动保存键置灰与冲突提示),随输入实时更新。
  String _key = '';
  late VariableAccess _access = widget.initialAccess;

  @override
  void initState() {
    super.initState();
    _key = widget.initialKey;
  }

  @override
  void dispose() {
    _keyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  /// 输入的键是否已被另一条变量占用(保存将覆盖那条)。
  bool get _conflicts =>
      _key.trim().isNotEmpty && widget.existingKeys.contains(_key.trim());

  void _submit() {
    final key = _key.trim();
    if (key.isEmpty) return;
    Navigator.pop(
      context,
      VariableEditResult(key, _valueController.text.trim(), _access),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 软键盘底高:键盘弹起时整区抬升,保证保存键可见可点。
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    InputDecoration decoration(String label, String hint) => InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: scheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
    );

    return Align(
      alignment: Alignment.bottomCenter,
      // heightFactor=1:整块按内容高度收缩,不撑满整屏(与其余底单一致)。
      heightFactor: 1,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Material(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, 12, 12, bottomInset > 0 ? 12 : 20),
            // 键盘弹起 + 新增权限下拉后内容可能超过可视高度:可滚动,
            // 不让保存键被顶出屏幕。
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: scheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _keyController,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    onChanged: (v) => setState(() => _key = v),
                    decoration: decoration('键', '如 hp / location'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _valueController,
                    minLines: 3,
                    maxLines: 6,
                    keyboardType: TextInputType.multiline,
                    decoration: decoration('值', '如 8/10').copyWith(
                      suffixIcon: CopyTextButton(controller: _valueController),
                      suffixIconConstraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<VariableAccess>(
                    // initialValue 只在首次构建生效:权限变化后换 key 重建,
                    // 让底单始终显示当前选择。
                    key: ValueKey('variable_access_${_access.name}'),
                    initialValue: _access,
                    isExpanded: true,
                    decoration: decoration('后台权限', '控制后台 agent 对该变量的改/删权限'),
                    items: [
                      for (final access in VariableAccess.values)
                        DropdownMenuItem(
                          value: access,
                          child: Text(
                            access.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _access = value);
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 4),
                    child: Text(
                      '${_access.description}。只影响后台 agent,不改写剧情正文。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (_conflicts)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '已存在同名变量,保存将覆盖它的值。',
                        style: TextStyle(color: scheme.error, fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '删除的变量会进入回收站,可在状态面板恢复',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      FilledButton.icon(
                        onPressed: _key.trim().isEmpty ? null : _submit,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
