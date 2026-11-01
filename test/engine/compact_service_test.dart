import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/backend/llm_backend.dart';
import 'package:microscritt/data/character_repository.dart';
import 'package:microscritt/data/database.dart';
import 'package:microscritt/data/message_repository.dart';
import 'package:microscritt/data/session_repository.dart';
import 'package:microscritt/engine/compact_service.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/token_usage.dart';
import '../support/test_database.dart';

class _FakeBackend implements LlmBackend {
  final String summary;
  final TokenUsage? usage;

  /// 最近一次收到的请求(验证合并式摘要把既有摘要作为背景送入)。
  LlmRequest? lastRequest;
  _FakeBackend(this.summary, {this.usage});

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) async* {
    lastRequest = request;
    yield TextDelta(summary);
    if (usage != null) yield UsageEvent(usage!);
    yield const DoneEvent();
  }
}

/// 前 [failures] 次调用报错,之后返回固定摘要(验证摘要失败重试)。
class _FlakySummaryBackend implements LlmBackend {
  final int failures;
  int calls = 0;
  _FlakySummaryBackend(this.failures);

  @override
  String get id => 'fake';

  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    if (calls <= failures) {
      return Stream.fromIterable(const [ErrorEvent('gateway boom')]);
    }
    return Stream.fromIterable(const [TextDelta('RETRIED-SUMMARY'), DoneEvent()]);
  }
}

/// 每次调用都报错并计数(验证重试耗尽 / foldToFit 不经 LLM)。
class _AlwaysErrorBackend implements LlmBackend {
  int calls = 0;
  @override
  String get id => 'fake';
  @override
  Stream<LlmEvent> generate(LlmRequest request) {
    calls++;
    return Stream.fromIterable(const [ErrorEvent('always down')]);
  }
}

void main() {
  late AppDatabase db;
  late MessageRepository messages;
  late SessionRepository sessions;
  late CharacterRepository characters;

  setUp(() async {
    db = await openTestDb();
    messages = MessageRepository(db);
    sessions = SessionRepository(db);
    characters = CharacterRepository(db);
  });

  Future<int> seedSession(int count) async {
    final charId = await characters.insert(const CharacterCard(name: 'A'));
    final sessionId = await sessions.create(charId, 's1');
    for (var i = 0; i < count; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'm$i');
    }
    return sessionId;
  }

  test('compacts oldest messages into a summary and marks originals', () async {
    final sessionId = await seedSession(25);
    final service = CompactService(_FakeBackend('SUMMARY'), messages);

    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20);

    expect(changed, isTrue);
    final all = await messages.bySession(sessionId);
    final summaries = all.where((m) => m.role == 'system').toList();
    expect(summaries.length, 1);
    expect(summaries.single.content, 'SUMMARY');

    final compacted = all.where((m) => m.isCompacted).toList();
    expect(compacted.length, 5); // 25 live - 20 kept
    expect(compacted.every((m) => m.compactOf == summaries.single.id), isTrue);
  });

  test('second compaction merges the previous summary and folds it', () async {
    // 合并式单一摘要:第二次压缩把既有摘要作为「早期背景」随转录送入模型,
    // 要求产出可完全替代旧摘要的新版;旧摘要行与新摘要落库同一事务被折叠
    // (is_compacted=1、compact_of 指向新摘要行)—— 线上摘要段永远只有一份
    // 最新、无矛盾的摘要,不随压缩次数堆叠。
    final sessionId = await seedSession(25);
    final changed = await CompactService(_FakeBackend('S1'), messages)
        .compact(sessionId: sessionId, model: 'fake', keep: 20);
    expect(changed, isTrue);

    for (var i = 25; i < 35; i++) {
      await messages.append(sessionId: sessionId, role: i.isEven ? 'user' : 'assistant', content: 'm$i');
    }
    final second = _FakeBackend('S2');
    final again = await CompactService(second, messages)
        .compact(sessionId: sessionId, model: 'fake', keep: 20);
    expect(again, isTrue);

    // 摘要请求携带既有摘要背景块(S1 全文)与新转录。
    final prompt = second.lastRequest!.messages.single.content;
    expect(prompt, contains('既有摘要'));
    expect(prompt, contains('S1'));
    expect(prompt, contains('m5'));

    final all = await messages.bySession(sessionId);
    final summaries = all.where((m) => m.role == 'system').toList();
    expect(summaries.length, 2, reason: '旧摘要行仍在库中(只折叠、不删除)');
    final live = summaries.where((m) => !m.isCompacted).toList();
    expect(live.single.content, 'S2', reason: '未折叠摘要恒只有一条且为最新');
    final folded = summaries.where((m) => m.isCompacted).single;
    expect(folded.content, 'S1');
    expect(folded.compactOf, live.single.id, reason: '旧摘要折叠记账指向新摘要行');
  });

  test('foldToFit carries the live summary forward and folds the old row', () async {
    // 机械折叠兜底时 LLM 不可用,既有摘要文本必须随新注记行一并承接(剧情
    // 摘要不能丢),旧摘要行同时折叠 —— 合并式不变量在兜底路径同样成立。
    final sessionId = await seedSession(25);
    await CompactService(_FakeBackend('S1'), messages)
        .compact(sessionId: sessionId, model: 'fake', keep: 20);

    final folded = await CompactService(_AlwaysErrorBackend(), messages)
        .foldToFit(sessionId: sessionId, keep: 6);
    expect(folded, isTrue);

    final all = await messages.bySession(sessionId);
    final summaries = all.where((m) => m.role == 'system').toList();
    expect(summaries.length, 2);
    final live = summaries.where((m) => !m.isCompacted).single;
    expect(live.content, contains('系统注记'));
    expect(live.content, contains('S1'), reason: '注记行须承接此前摘要文本');
    final old = summaries.where((m) => m.isCompacted).single;
    expect(old.content, 'S1');
  });

  test('does nothing when under the keep threshold', () async {
    final sessionId = await seedSession(10);
    final service = CompactService(_FakeBackend('SUMMARY'), messages);

    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20);

    expect(changed, isFalse);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);
  });

  test('returns false when the backend emits no text', () async {
    final sessionId = await seedSession(25);
    final service = CompactService(_FakeBackend(''), messages);

    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20);

    expect(changed, isFalse);
    expect((await messages.bySession(sessionId)).where((m) => m.role == 'system'), isEmpty);
  });

  test('waits for the minChunk before compacting (rate-limited auto compact)', () async {
    // 自动路径按块降频(minChunk >1):掉出窗口的消息积攒够一批才压缩,
    // 压缩间隔内不再每轮追加摘要 system 行 —— 摘要段字节稳定,缓存不随
    // 每轮被破坏。默认 minChunk=1 保持旧行为(即时压缩)。
    final sessionId = await seedSession(25); // 25 条活跃:掉出 5 条 < 10
    final service = CompactService(_FakeBackend('SUMMARY'), messages);

    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20, minChunk: 10);

    expect(changed, isFalse);
    var all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);

    // 积攒到 30 条(掉出 10 条)后压缩执行。
    await messages.append(sessionId: sessionId, role: 'user', content: 'm25');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'm26');
    await messages.append(sessionId: sessionId, role: 'user', content: 'm27');
    await messages.append(sessionId: sessionId, role: 'assistant', content: 'm28');
    await messages.append(sessionId: sessionId, role: 'user', content: 'm29');
    final later = await service.compact(sessionId: sessionId, model: 'fake', keep: 20, minChunk: 10);
    expect(later, isTrue);
    all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system').length, 1);
    expect(all.where((m) => m.isCompacted).length, 10); // 25 条中的前 10 条被压缩
  });

  test('reports the summarization token usage via onUsage (D2)', () async {
    final sessionId = await seedSession(25);
    final service = CompactService(
      _FakeBackend('SUMMARY', usage: const TokenUsage(inputTokens: 40, outputTokens: 9, cachedInputTokens: 20)),
      messages,
    );
    TokenUsage? reported;
    final changed = await service.compact(
      sessionId: sessionId,
      model: 'fake',
      keep: 20,
      onUsage: (u) => reported = u,
    );

    expect(changed, isTrue);
    expect(reported!.inputTokens, 40);
    expect(reported!.outputTokens, 9);
    expect(reported!.cachedInputTokens, 20);
  });

  test('does not call onUsage when under the keep threshold', () async {
    final sessionId = await seedSession(10);
    final service = CompactService(_FakeBackend('SUMMARY'), messages);
    var called = false;
    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20, onUsage: (_) => called = true);
    expect(changed, isFalse);
    expect(called, isFalse);
  });

  test('formatCompactSummary strips analysis scratchpad and summary tags', () {
    final raw = '''
<analysis>
这是一段思考草稿,不应落库。
</analysis>
<summary>
1. 剧情主线:主角抵达旧城。
2. 角色与关系:艾琳保持警惕。
</summary>
''';
    final out = formatCompactSummary(raw);
    expect(out.contains('analysis'), isFalse);
    expect(out.contains('<summary>'), isFalse);
    expect(out.contains('这是一段思考草稿'), isFalse);
    expect(out, contains('主角抵达旧城'));
    expect(out, contains('艾琳保持警惕'));
    // 分段结构保留,草稿未污染正文。
    expect(out.startsWith('1. 剧情主线'), isTrue);
  });

  test('formatCompactSummary passes through plain text without tags', () {
    // 模型未按标签输出时的宽松回退:原样保留,仅去除首尾空白。
    expect(formatCompactSummary('  摘要正文  '), '摘要正文');
    expect(formatCompactSummary('SUMMARY'), 'SUMMARY');
  });

  test('formatted summary is stored clean (analysis stripped before persist)', () async {
    final sessionId = await seedSession(25);
    final service = CompactService(
      _FakeBackend('<analysis>草稿</analysis>\n<summary>干净摘要</summary>'),
      messages,
    );

    await service.compact(sessionId: sessionId, model: 'fake', keep: 20);

    final all = await messages.bySession(sessionId);
    final summary = all.where((m) => m.role == 'system').single;
    expect(summary.content, '干净摘要');
    expect(summary.content.contains('<summary>'), isFalse);
  });

  test('retries the summarization on failure and succeeds within budget', () async {
    // 摘要调用前两次报错,第 3 次成功:maxSummarizeAttempts=4(首次+3 重试)内完成。
    final sessionId = await seedSession(25);
    final backend = _FlakySummaryBackend(2);
    final service = CompactService(backend, messages);

    final changed = await service.compact(
      sessionId: sessionId,
      model: 'fake',
      keep: 20,
      maxSummarizeAttempts: 4,
    );

    expect(changed, isTrue);
    expect(backend.calls, 3);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system').single.content, 'RETRIED-SUMMARY');
    expect(all.where((m) => m.isCompacted).length, 5);
  });

  test('gives up after exhausting summarize retries and writes nothing', () async {
    // 一直失败:4 次尝试全部耗尽 → 返回 false,不落任何摘要/标记。
    final sessionId = await seedSession(25);
    final backend = _AlwaysErrorBackend();
    final service = CompactService(backend, messages);

    final changed = await service.compact(
      sessionId: sessionId,
      model: 'fake',
      keep: 20,
      maxSummarizeAttempts: 4,
    );

    expect(changed, isFalse);
    expect(backend.calls, 4); // 首次 + 3 次重试
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);
  });

  test('defaults to a single attempt (no retry) when attempts not requested', () async {
    // 未传 maxSummarizeAttempts 保持旧行为:只试一次。
    final sessionId = await seedSession(25);
    final backend = _FlakySummaryBackend(1);
    final service = CompactService(backend, messages);

    final changed = await service.compact(sessionId: sessionId, model: 'fake', keep: 20);

    expect(changed, isFalse);
    expect(backend.calls, 1);
  });

  test('foldToFit marks overflow compacted with a system note and never calls the LLM', () async {
    final sessionId = await seedSession(25);
    final backend = _AlwaysErrorBackend();
    final service = CompactService(backend, messages);

    final folded = await service.foldToFit(sessionId: sessionId, keep: 6);

    expect(folded, isTrue);
    expect(backend.calls, 0); // 机械截断不经 LLM
    final all = await messages.bySession(sessionId);
    final note = all.where((m) => m.role == 'system').single;
    expect(note.content, contains('系统注记'));
    // 25 - 6 = 19 条被折叠,且都指向同一条注记行。
    final compacted = all.where((m) => m.isCompacted).toList();
    expect(compacted.length, 19);
    expect(compacted.every((m) => m.compactOf == note.id), isTrue);
  });

  test('foldToFit does nothing when history fits', () async {
    final sessionId = await seedSession(5);
    final service = CompactService(_AlwaysErrorBackend(), messages);

    final folded = await service.foldToFit(sessionId: sessionId, keep: 6);

    expect(folded, isFalse);
    final all = await messages.bySession(sessionId);
    expect(all.where((m) => m.role == 'system'), isEmpty);
    expect(all.where((m) => m.isCompacted), isEmpty);
  });
}
