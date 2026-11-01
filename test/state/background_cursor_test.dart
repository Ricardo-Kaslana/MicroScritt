import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/backend_config.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/engine/background_status.dart';
import 'package:microscritt/engine/hook_runtime.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/state/chat_controller.dart';
import 'package:microscritt/state/providers.dart';
import 'package:microscritt/state/slash_commands.dart';
import '../support/test_database.dart';

/// 主写轮(奇数次)吐正文;后台轮(偶数次)吐合法快状态 JSON —— 后台因此能成功
/// 并推进增量游标,复现「游标已推进」之后再做尾巴重写的场景。
class _MainThenBackgroundBackend implements LlmBackend {
  int calls = 0;

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls.isOdd) {
      return Stream.fromIterable(const [TextDelta('reply.'), DoneEvent()]);
    }
    return Stream.fromIterable(const [
      TextDelta('{"activeSkills":[],"variables":{},"memory":"m"}'),
      DoneEvent(),
    ]);
  }
}

class _NoopRuntime implements HookRuntime {
  @override
  Future<String?> evaluate(String js) async => null;
}

/// 历史改写会复用 seq,必须使旧后台任务和处理进度同时失效。
void main() {
  late AppDatabase db;
  late int sessionId;

  setUp(() async {
    db = await openTestDb();
    final charId = await CharacterRepository(db).insert(const CharacterCard(name: 'Alice'));
    sessionId = await SessionRepository(db).create(charId, 's1');
  });

  ProviderContainer makeContainer(LlmBackend backend) => ProviderContainer(
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
      backendProvider.overrideWith((ref) => backend),
      hookRuntimeProvider.overrideWith((ref) => _NoopRuntime()),
    ],
  );

  Future<void> awaitBackground(ProviderContainer container) async {
    final task = container.read(chatControllerProvider.notifier).backgroundTask;
    if (task != null) await task;
  }

  /// `role@seq` 形状的行摘要,便于直接断言 seq 复用。
  Future<List<String>> shape() async =>
      (await MessageRepository(db).bySession(sessionId)).map((m) => '${m.role}@${m.seq}').toList();

  test('regenerate does not get skipped by a stale background cursor', () async {
    final container = makeContainer(_MainThenBackgroundBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    const card = CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionId, character: card);

    // 首轮发送:后台成功并把游标推进到本轮最大 seq。
    await controller.send('hello');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
    expect(await shape(), ['user@0', 'assistant@1']);

    // 重新生成:剪掉尾巴后重写的回复**复用 seq 1** —— 游标若不清掉,这一轮后台
    // 会以「无新对话可维护」跳过(修复前实测复现)。
    final assistantId =
        (await MessageRepository(db).bySession(sessionId)).lastWhere((m) => m.role == 'assistant').id!;
    await controller.regenerate(assistantId);
    await awaitBackground(container);
    final afterRegen = container.read(chatControllerProvider);
    expect(await shape(), ['user@0', 'assistant@1'], reason: 'seq 复用正是这条回归的成因');
    expect(
      afterRegen.backgroundStatus,
      BackgroundStatus.succeeded,
      reason: '重新生成后后台仍应触发,不该被陈旧游标跳过',
    );
    expect(afterRegen.backgroundSummary, isNot(contains('无新对话可维护')));
  });

  test('resend does not get skipped by a stale background cursor', () async {
    final container = makeContainer(_MainThenBackgroundBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    const card = CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionId, character: card);
    await controller.send('hello');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);

    // 重新发送:整段回滚后重放,新行同样复用 seq 0/1。
    final userId = (await MessageRepository(db).bySession(sessionId)).firstWhere((m) => m.role == 'user').id!;
    await controller.resend(userId);
    await awaitBackground(container);
    final afterResend = container.read(chatControllerProvider);
    expect(await shape(), ['user@0', 'assistant@1']);
    expect(
      afterResend.backgroundStatus,
      BackgroundStatus.succeeded,
      reason: '重新发送后后台仍应触发,不该被陈旧游标跳过',
    );
    expect(afterResend.backgroundSummary, isNot(contains('无新对话可维护')));
  });

  test('clear history does not get skipped by a stale background cursor', () async {
    final container = makeContainer(_MainThenBackgroundBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    const card = CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionId, character: card);
    await controller.send('hello');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);

    // /clear 后 seq 重新从 0 开始(角色未配开场白 → 空历史);再发一轮,后台
    // 不该因为游标停在清空前的最大值而跳过。
    await controller.runCommand(SlashCommand.clearHistory);
    await controller.send('after clear');
    await awaitBackground(container);
    final afterClear = container.read(chatControllerProvider);
    expect(
      afterClear.backgroundStatus,
      BackgroundStatus.succeeded,
      reason: '清空历史后首轮后台仍应触发',
    );
  });

  test('clearing a paged long session does not consume the first new turn without maintenance', () async {
    final backend = _MainThenBackgroundBackend();
    final container = makeContainer(backend);
    addTearDown(container.dispose);
    final messages = MessageRepository(db);
    for (var i = 0; i < 400; i++) {
      await messages.append(
        sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'old $i',
      );
    }
    final controller = container.read(chatControllerProvider.notifier);
    await controller.load(sessionId: sessionId, character: const CharacterCard(name: 'Alice'));
    expect(container.read(chatControllerProvider).canLoadOlder, isTrue);
    await controller.runCommand(SlashCommand.clearHistory);
    await controller.send('new beginning');
    await awaitBackground(container);
    expect(backend.calls, 2);
    expect(await shape(), ['user@0', 'assistant@1']);
    expect(container.read(chatControllerProvider).messages.map((m) => m.content), ['new beginning', 'reply.']);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);
  });

  test('deleting the tail messages does not leave a stale cursor behind', () async {
    final container = makeContainer(_MainThenBackgroundBackend());
    addTearDown(container.dispose);
    final controller = container.read(chatControllerProvider.notifier);
    const card = CharacterCard(name: 'Alice');

    await controller.load(sessionId: sessionId, character: card);
    await controller.send('hello');
    await awaitBackground(container);
    expect(container.read(chatControllerProvider).backgroundStatus, BackgroundStatus.succeeded);

    // 删掉整段对话:尾部行被删 → 后续 append 复用被释放的 seq;再发一轮,游标
    // 若停在删除前的最大值,新行全落在游标之内 → 后台以「无新对话可维护」跳过。
    final rows = await MessageRepository(db).bySession(sessionId);
    for (final m in rows.reversed) {
      await controller.deleteMessage(m.id!);
    }
    expect(await shape(), isEmpty);

    await controller.send('again');
    await awaitBackground(container);
    expect(
      container.read(chatControllerProvider).backgroundStatus,
      BackgroundStatus.succeeded,
      reason: '删除尾部消息后,后续一轮后台不该被陈旧游标跳过',
    );
  });
}
