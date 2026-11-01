import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/context/attachment_budget.dart';

/// DG 批:单轮附件注入预算与类型优先级(纯函数)。
void main() {
  AttachmentCandidate cand(AttachmentOrigin origin, String ref) =>
      AttachmentCandidate(origin: origin, refId: ref, content: 'body-$ref');

  test('exempt origins (skill/notice) always pass regardless of budget', () {
    final picked = selectWithinBudget([
      cand(AttachmentOrigin.skill, 'skill:1'),
      cand(AttachmentOrigin.notice, 'notice:compact:9'),
      cand(AttachmentOrigin.notice, 'notice:memdiff:3'),
    ], 0);
    expect(picked.map((c) => c.refId), ['skill:1', 'notice:compact:9', 'notice:memdiff:3']);
  });

  test('budgeted origins (worldbook) are truncated by cap in order', () {
    final picked = selectWithinBudget([
      cand(AttachmentOrigin.worldbook, 'wb:1'),
      cand(AttachmentOrigin.worldbook, 'wb:2'),
      cand(AttachmentOrigin.worldbook, 'wb:3'),
      cand(AttachmentOrigin.worldbook, 'wb:4'),
    ], 2);
    expect(picked.map((c) => c.refId), ['wb:1', 'wb:2']);
  });

  test('cap 0 disables auto attachments but keeps exempt ones, exempt first', () {
    final picked = selectWithinBudget([
      cand(AttachmentOrigin.worldbook, 'wb:1'),
      cand(AttachmentOrigin.skill, 'skill:7'),
      cand(AttachmentOrigin.worldbook, 'wb:2'),
    ], 0);
    expect(picked.map((c) => c.refId), ['skill:7']);
  });

  test('cap larger than candidate count keeps all budgeted items', () {
    final picked = selectWithinBudget([
      cand(AttachmentOrigin.skill, 'skill:1'),
      cand(AttachmentOrigin.worldbook, 'wb:1'),
      cand(AttachmentOrigin.worldbook, 'wb:2'),
    ], 10);
    expect(picked.map((c) => c.refId), ['skill:1', 'wb:1', 'wb:2']);
  });

  test('negative cap behaves like 0', () {
    final picked = selectWithinBudget([cand(AttachmentOrigin.worldbook, 'wb:1')], -3);
    expect(picked, isEmpty);
  });
}
