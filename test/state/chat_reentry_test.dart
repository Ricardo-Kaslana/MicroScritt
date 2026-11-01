import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/token_usage.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/state/slash_commands.dart';
import '../support/test_database.dart';

class _FakeBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) =>
      Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
}

/// 主写请求附带真实用量(模拟服务端 UsageEvent 终值)。
class _UsageBackend implements LlmBackend {
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) => Stream.fromIterable(const [
    TextDelta('reply.'),
    UsageEvent(TokenUsage(inputTokens: 1234, outputTokens: 56, cachedInputTokens: 100)),
    DoneEvent(),
  ]);
}

/// 首个请求上报用量、之后不再上报 —— 模拟网关间歇性缺 usage。
class _UsageThenSilentBackend implements LlmBackend {
  int _calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    _calls += 1;
    return Stream.fromIterable(<LlmEvent>[
      const TextDelta('reply.'),
      if (_calls == 1)
        const UsageEvent(TokenUsage(inputTokens: 1234, outputTokens: 56, cachedInputTokens: 100)),
      const DoneEvent(),
    ]);
  }
}

class _NoopRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => null;
}

/// 复现用户报告的「二次进入同一会话消息列表为空」:
/// 进入 A → 退出 → 再进 A(为空)→ 进 B(正常)→ 再进 A(又正常)。
/// chatControllerProvider 是全局非 autoDispose 的,退出聊天页不清控制器状态,
/// 因此这里的连续 load 序列即真实导航路径。
void main() {
  late AppDatabase db;
  late int sessionA;
  late int sessionB;

  setUp(() async {
    db = await openTestDb();
    final characters = CharacterRepository(db);
    final sessions = SessionRepository(db);
    final charId = await characters.insert(const CharacterCard(name: 'Alice'));
    sessionA = await sessions.create(charId, 'A');
    sessionB = await sessions.create(charId, 'B');
    // A 种入超过显示窗口(300 行)的消息,让窗口化加载(floor != null)生效。
    for (var i = 0; i < 200; i++) {
      await MessageRepository(db).append(sessionId: sessionA, role: 'user', content: 'u-$i');
      await MessageRepository(db).append(sessionId: sessionA, role: 'assistant', content: 'a-$i');
    }
    await MessageRepository(db).append(sessionId: sessionB, role: 'user', content: 'hello B');
  });

  ProviderContainer makeContainer({LlmBackend? backend}) => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      backendConfigProvider.overrideWith(
        (ref) => const BackendConfig(
          provider: BackendProvider.openai,
          baseUrl: 'https://api.openai.com/v1',
          apiKey: 'sk-test',
          model: 'gpt-4o',
        ),
      ),
      backendProvider.overrideWith((ref) => backend ?? _FakeBackend()),
      hookRuntimeProvider.overrideWith((ref) => _NoopRuntime()),
    ],
  );

  test('re-entering the same session keeps the message window populated', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    // 首次进入 A。
    await controller.load(sessionId: sessionA, character: card);
    final firstLoad = container.read(chatControllerProvider).messages;
    expect(firstLoad, isNotEmpty, reason: '首次进入 A 应有消息');

    // 退出后再次进入 A(控制器状态仍停留在上一次的 A)。
    await controller.load(sessionId: sessionA, character: card);
    final secondLoad = container.read(chatControllerProvider);
    expect(secondLoad.sessionId, sessionA);
    expect(secondLoad.messages, isNotEmpty, reason: '二次进入 A 不应丢失消息窗口');
    expect(secondLoad.messages.length, firstLoad.length);
    expect(secondLoad.canLoadOlder, isTrue);
  });

  test('A -> B -> A sequence keeps every entry populated', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionA, character: card);
    expect(container.read(chatControllerProvider).messages, isNotEmpty);

    // 再进 A(报障路径),随后切到 B。
    await controller.load(sessionId: sessionA, character: card);
    expect(container.read(chatControllerProvider).messages, isNotEmpty);

    await controller.load(sessionId: sessionB, character: card);
    final bState = container.read(chatControllerProvider);
    expect(bState.sessionId, sessionB);
    expect(bState.messages, isNotEmpty, reason: '进入 B 应正常');

    // 从 B 退出再进 A。
    await controller.load(sessionId: sessionA, character: card);
    final backToA = container.read(chatControllerProvider);
    expect(backToA.sessionId, sessionA);
    expect(backToA.messages, isNotEmpty, reason: 'B -> A 再进也应正常');
    expect(backToA.messages.length, container.read(chatControllerProvider).messages.length);
  });

  test('re-entry after loadOlder paging keeps the window consistent', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionA, character: card);
    expect(container.read(chatControllerProvider).canLoadOlder, isTrue);

    // 首次访问里向上翻一页历史(贴顶分页),窗口下界随之前移。
    await controller.loadOlder();
    final paged = container.read(chatControllerProvider);
    expect(paged.messages.length, greaterThan(300), reason: '分页后应补进一页历史');

    // 退出后再进 A:窗口应按全新游标重建,而不是沿用残留状态。
    await controller.load(sessionId: sessionA, character: card);
    final reentry = container.read(chatControllerProvider);
    expect(reentry.messages, isNotEmpty);
    // 重新进入 = 全新初始窗口(显示尾部 300 行),首次访问里分页补进的历史
    // 不应泄漏进来;canLoadOlder 仍为 true,更早历史照常可再翻。
    expect(reentry.messages.length, 300, reason: '重进应回到初始窗口而非残留分页状态');
    expect(reentry.canLoadOlder, isTrue);
  });

  test('send re-anchors the real input; only a full rewrite invalidates it', () async {
    final container = makeContainer(backend: _UsageBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    // 未发送过:无真实锚点。
    await controller.load(sessionId: sessionA, character: card);
    expect(container.read(chatControllerProvider).lastSentInputTokens, isNull);

    // 发送一轮:锚点 = 本轮主写请求的服务端精确输入计数。
    await controller.send('hello');
    expect(container.read(chatControllerProvider).lastSentInputTokens, 1234);

    // 编辑单条消息:局部改写,锚点保留(圆环不退回字符估算)。
    final firstId = (await MessageRepository(db).bySession(sessionA)).first.id!;
    await controller.editMessage(firstId, 'edited');
    expect(container.read(chatControllerProvider).lastSentInputTokens, 1234,
        reason: '编辑单条消息不足以让上轮真实计数失效');

    // 删除单条消息:同样保留。
    await controller.deleteMessage(firstId);
    expect(container.read(chatControllerProvider).lastSentInputTokens, 1234,
        reason: '删除单条消息同样保留锚点');

    // 记忆应用到上下文:第 0 条换新,仍保留锚点。
    await controller.applyMemoryToContext();
    expect(container.read(chatControllerProvider).lastSentInputTokens, 1234,
        reason: '换第 0 条记忆对整体规模改动有限,保留锚点');

    // /clear 整体重写历史:旧值对下一次请求已无意义,锚点失效。
    await controller.runCommand(SlashCommand.clearHistory);
    expect(container.read(chatControllerProvider).lastSentInputTokens, isNull,
        reason: '清空历史后旧的真实计数已失效');
  });

  test('gateway silence on a later turn keeps the last known real anchor', () async {
    final container = makeContainer(backend: _UsageThenSilentBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionA, character: card);
    await controller.send('hello');
    expect(container.read(chatControllerProvider).lastSentInputTokens, 1234);

    // 第二轮网关没回 usage:沿用上一次已知的真实值,不当场退回字符估算。
    await controller.send('again');
    final state = container.read(chatControllerProvider);
    expect(state.lastSentInputTokens, 1234, reason: '网关未上报时沿用上次真实锚点');
    // 输入侧记账一并沿用 —— 会话行持久化后重进仍能恢复锚点。
    expect(state.inputTokens, 1234);
  });

  test('load restores the real anchor from the persisted last-round usage', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    final card = const CharacterCard(name: 'Alice');

    // 会话行持久化的是"最近一轮主写请求"的实际输入(每轮替换口径)。
    await SessionRepository(db).updateTokenUsage(
      sessionId: sessionA,
      inputTokens: 999,
      outputTokens: 11,
      cachedInputTokens: 0,
      backgroundInputTokens: 0,
      backgroundOutputTokens: 0,
      backgroundCachedInputTokens: 0,
      compactInputTokens: 0,
      compactOutputTokens: 0,
      compactCachedInputTokens: 0,
    );
    await controller.load(sessionId: sessionA, character: card);
    expect(container.read(chatControllerProvider).lastSentInputTokens, 999,
        reason: '重进会话后圆环应立即回到真实口径');
  });
}
