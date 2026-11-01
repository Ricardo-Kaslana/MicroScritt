import 'package:flutter/material.dart';

import 'copy_button.dart';

/// 通用底部文本编辑区:弹出后返回用户保存的新文本,取消返回 null。
///
/// 随软键盘整体抬升(按 `viewInsets` 垫高),编辑区高度充裕(长文内部滚动),
/// 空文本(仅空白)不可保存。消息编辑与后台记忆编辑共用此底单。
Future<String?> showTextEditSheet(
  BuildContext context, {
  required String title,
  required String initialText,
  String hintText = '输入新内容…',
  // 记忆等需要长文编辑的调用方可以传更高的编辑区;默认与消息编辑一致。
  double editorHeightFactor = 0.55,
  double maxEditorHeight = 420,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _TextEditSheet(
      title: title,
      initialText: initialText,
      hintText: hintText,
      editorHeightFactor: editorHeightFactor,
      maxEditorHeight: maxEditorHeight,
    ),
  );
}

class _TextEditSheet extends StatefulWidget {
  final String title;
  final String initialText;
  final String hintText;
  final double editorHeightFactor;
  final double maxEditorHeight;
  const _TextEditSheet({
    required this.title,
    required this.initialText,
    required this.hintText,
    required this.editorHeightFactor,
    required this.maxEditorHeight,
  });

  @override
  State<_TextEditSheet> createState() => _TextEditSheetState();
}

class _TextEditSheetState extends State<_TextEditSheet> {
  /// 编辑框控制器:由本 State 自建自养,底单关闭动画结束后随 dispose 释放,
  /// 避免"路由还在退场、控制器已被外部 dispose"的 use-after-dispose。
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialText,
  );

  /// 当前文本,驱动保存键置灰与字数统计。
  String _text = '';

  @override
  void initState() {
    super.initState();
    _text = widget.initialText;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) => setState(() => _text = v);

  void _submit() {
    // 空文本(仅空白)不保存:直接取消,避免把内容改空。
    if (_text.trim().isEmpty) {
      Navigator.pop(context);
      return;
    }
    Navigator.pop(context, _text);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 软键盘底高:keyboard 弹起时整区抬升,保证保存键始终可见可点。
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    // 编辑区高度:默认取屏幕 ~55% 且封顶 420;记忆等长文场景由调用方
    // 传入更大的比例/上限。可用高度不足时由外层 Flexible 收缩让位。
    final editorHeight =
        (MediaQuery.sizeOf(context).height * widget.editorHeightFactor).clamp(
          140.0,
          widget.maxEditorHeight,
        );

    return Align(
      alignment: Alignment.bottomCenter,
      // heightFactor=1:让整个编辑区按内容高度收缩,而不是撑满整屏 ——
      // 否则(isScrollControlled 给到全屏高)Align 占满高度,整块 sheet
      // 表面被拉满,标题上方留下一大块空白。
      heightFactor: 1,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        // 与其余底单一致占满整宽(不做桌面限宽):限宽会在宽屏上两侧
        // 留出一大片空白,与本 App 其它底单/输入区风格不符。
        child: Material(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.9,
            ),
            child: Padding(
              // 左右留 12 与聊天输入胶囊(12/4/12/8)对齐,不再有额外宽边距。
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                bottomInset > 0 ? 12 : 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 拖拽把手 + 标题 + 取消。
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
                      CopyTextButton(controller: _controller),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('取消'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 编辑主体:多行输入,长文内部滚动。空间充裕时占满期望高度
                  // (editorHeight),可用高度不足(小窗/键盘弹起)时收缩让位,
                  // 避免固定高度把 Column 撑爆溢出。
                  Flexible(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: 120,
                        maxHeight: editorHeight,
                      ),
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest.withValues(
                            alpha: 0.6,
                          ),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: scheme.outlineVariant.withValues(alpha: 0.5),
                          ),
                        ),
                        child: TextField(
                          controller: _controller,
                          autofocus: true,
                          maxLines: null,
                          expands: true,
                          textAlignVertical: TextAlignVertical.top,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                          onChanged: _onChanged,
                          style: const TextStyle(fontSize: 15, height: 1.4),
                          decoration: InputDecoration(
                            hintText: widget.hintText,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.all(12),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 底部一行:字数统计 + 保存。
                  Row(
                    children: [
                      Text(
                        '${_text.length} 字符',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const Expanded(child: SizedBox.shrink()),
                      FilledButton.icon(
                        onPressed: _text.trim().isEmpty ? null : _submit,
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
