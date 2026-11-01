// 上下文预算测试:占用率挡位阈值、请求 token 估算与保留条数规划。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/context_budget.dart';
import 'package:microscritt/models/chat_message.dart';
import 'package:microscritt/models/message.dart';

Message _m(String content, int seq) => Message(sessionId: 1, role: 'user', content: content, seq: seq);

void main() {
  group('budgetLevelFor(占用率 → 挡位)', () {
    test('低于软挡为 ok', () {
      expect(budgetLevelFor(0.0), ContextBudgetLevel.ok);
      expect(budgetLevelFor(0.59), ContextBudgetLevel.ok);
    });
    test('达软挡(60%)为 soft,未到硬挡仍为 soft', () {
      expect(budgetLevelFor(0.60), ContextBudgetLevel.soft);
      expect(budgetLevelFor(0.79), ContextBudgetLevel.soft);
    });
    test('达硬挡(80%)为 hard', () {
      expect(budgetLevelFor(0.80), ContextBudgetLevel.hard);
      expect(budgetLevelFor(0.99), ContextBudgetLevel.hard);
    });
  });

  group('estimateRequestTokens', () {
    test('system + messages(含第 0 条记忆/摘要与附件行)一并计入(与上下文圆环同一把尺子)', () {
      // 每段 32 字符 → (32 / 3.2).round() = 10 token。
      final tokens = estimateRequestTokens(
        systemPrompt: 'a' * 32,
        messages: [ChatMessage(ChatRole.user, 'b' * 32), ChatMessage(ChatRole.user, 'c' * 32)],
      );
      expect(tokens, 30);
    });
    test('无消息时只计 system', () {
      final tokens = estimateRequestTokens(
        systemPrompt: 'a' * 32,
        messages: const [],
      );
      expect(tokens, 10);
    });
  });

  group('planKeepWithinBudget(从最新往前规划保留条数)', () {
    test('预算充足时全部保留', () {
      final active = [for (var i = 0; i < 5; i++) _m('x' * 32, i)]; // 每条 ≈10 token
      expect(planKeepWithinBudget(active: active, budgetTokens: 1000), 5);
    });
    test('预算不足时保住最新的若干条', () {
      // 每条 ≈31 token;预算 40:从最新起第一条无条件进、第二条因 minKeep 无条件
      // 进(used=62),第三条 62+31>40 → 停。保留 2 条。
      final active = [for (var i = 0; i < 6; i++) _m('x' * 100, i)];
      expect(planKeepWithinBudget(active: active, budgetTokens: 40), 2);
    });
    test('预算为 0 也至少保留 minKeep 条(最新一问一答)', () {
      final active = [for (var i = 0; i < 4; i++) _m('y' * 320, i)];
      expect(planKeepWithinBudget(active: active, budgetTokens: 0), ContextBudgetPolicy.minKeepMessages);
    });
    test('空列表返回 0', () {
      expect(planKeepWithinBudget(active: const [], budgetTokens: 500), 0);
    });
    test('自定义 minKeep 生效', () {
      final active = [_m('a' * 3200, 0), _m('b' * 3200, 1)];
      // 预算 0,minKeep=1:仅保最新 1 条。
      expect(planKeepWithinBudget(active: active, budgetTokens: 0, minKeep: 1), 1);
    });
  });

  group('ContextBudgetPolicy 三挡常量', () {
    test('目标/软/硬挡分别为 20%/60%/80%', () {
      expect(ContextBudgetPolicy.target, 0.20);
      expect(ContextBudgetPolicy.soft, 0.60);
      expect(ContextBudgetPolicy.hard, 0.80);
    });
  });
}
