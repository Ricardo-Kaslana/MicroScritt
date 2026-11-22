/// 后台维护 profile(agentic 模式):工具契约提示词 + 工具面 + 内存暂存态。
/// 循环中一切写只改暂存;finish 后由编排器走原 compareAndApply 一次原子
/// 提交(权限事务内终裁/≤5 删除/回收站/严格提案零改)。中途失败/取消/护栏
/// 触发 → 暂存全丢弃。数据段与 legacy 单发逐字同构(background_prompt),
/// 契约文本改工具措辞;审计 profile(P4)将复用本文件的内核接线。
library;

import '../backend/llm_backend.dart';
import '../models/app_settings.dart';
import '../models/character_card.dart';
import '../models/llm_provider.dart';
import '../models/llm_tool.dart';
import '../models/message.dart';
import '../models/variable.dart';
import '../models/worldbook_entry.dart';
import 'agent/agent_events.dart';
import 'agent/agent_runner.dart';
import 'agent/agent_tool.dart';
import 'background_engine.dart';
import 'background_prompt.dart';

/// 历史搜索的一条轻量命中(编排器从消息仓储映射,profile 不 import data 层)。
typedef HistorySearchHit = ({int seq, String role, String content});

/// 历史搜索回调:字面量子串,返回最新命中;结果已按本轮可读窗口钳制。
typedef HistorySearch =
    Future<List<HistorySearchHit>> Function(String query, {int limit});

/// 一轮维护的内存暂存态:updates/removals 由构造保证不相交(每个写动作
/// 把键从对方集合移除),同键 last-action-wins;提交时直接喂
/// compareAndApply 的 updates/removals 参数。
class MaintenanceStaging {
  /// 快照基线(本轮开始时的变量板)。
  final Map<String, String> base;

  /// 既有键权限档;不在其中的键(本轮新建)默认 full。
  final Map<String, VariableAccess> access;

  /// 暂存更新(键 → 新值)。
  final Map<String, String> updates = {};

  /// 暂存删除(当前生效的删除键,提交用)。
  final List<String> removals = [];

  /// 曾暂存删除的**不同键**集合:累计帽按它计 —— remove→set→remove 同键
  /// 不重复计费,re-remove 免费;比「最终删除数」保守,防模型反复刷删除。
  final Set<String> everRemoved = {};

  /// 暂存生图描述(setImagePrompts 整组替换);null = 本轮未产出。
  List<String>? imagePrompts;

  /// 暂存的变量注入选择(setVariableInjection 整组替换):键按展示顺序排列,
  /// 值在提交后按最终变量板解析。null = 本轮未产出,[] = 显式清除。
  List<String>? injectionKeys;

  /// 暂存的下一步建议(setNextSuggestions 整组替换);null = 本轮未产出。
  List<String>? nextSuggestions;

  /// 暂存的记忆提议(整段替换文本):只交给用户审阅,提交时绝不写记忆库。
  String? memoryProposal;

  MaintenanceStaging({required this.base, required this.access});

  /// 工作副本:基线 − 暂存删除 + 暂存更新(readVariables 与删除校验用)。
  Map<String, String> get workingCopy {
    final copy = Map.of(base);
    for (final key in removals) {
      copy.remove(key);
    }
    copy.addAll(updates);
    return copy;
  }
}

/// 维护 profile 构建器:提示词 + 工具集 + 暂存态,产出可直接喂 AgentRunner
/// 的 spec。内核不认识变量/生图/数据库 —— 业务校验与暂存操作全在闭包里,
/// 读历史经编排器注入的只读回调(绑定 sessionId + clamp throughSeq)。
class MaintenanceProfile {
  /// 单轮累计删除帽(不同键):与仓库事务内终裁同值;工具层即时报错只为
  /// 回喂纠错,最终裁决仍在 compareAndApply。
  static const int maxRemovalsPerRun = 5;

  /// readHistory 每页字符帽(上下文尺寸护栏)。
  static const int readHistoryPageChars = 2000;

  /// readHistory 单页消息条数上限(字符帽之外的二级兜底)。
  static const int readHistoryPageLimit = 50;

  /// 变量注入单轮键数上限(附件体积护栏;提示词与工具 schema 同值)。
  static const int maxInjectionKeys = 8;

  /// readVariables 暂存更新的分页默认/上限条数(结果 JSON 预算)。
  static const int readVariablesPageDefault = 20;
  static const int readVariablesPageMax = 50;

  /// readVariables 单键/单值展示字符上限:超长内容只回缩略,配合 [kToolResultBudget]
  /// 让结果始终是合法 JSON 而不是被内核截成半截。
  static const int readVariableKeyChars = 120;
  static const int readVariableValueChars = 240;

  /// 下一步建议条数上限(底单尺寸护栏)。
  static const int maxNextSuggestions = 3;

  /// 单条建议字符上限(完整发言仍应短小可直接发送)。
  static const int maxNextSuggestionChars = 120;

  /// searchHistory 单次最多命中条数(工具结果体积护栏)。
  static const int searchHistoryMaxHits = 5;

  /// 每条搜索命中的正文字符上限。
  static const int searchHitChars = 120;

  /// 搜索词字符上限:超长词几乎必然无命中,本地直接拒绝。
  static const int searchQueryMaxChars = 200;

  /// readHistory 邻近窗口:中心前后各取几条、单行截断长度。
  static const int aroundWindowBefore = 2;
  static const int aroundWindowAfter = 2;
  static const int aroundLineChars = 320;

  /// validateStaged 最多报告的重复键组数(结果体积护栏)。
  static const int maxDuplicateKeyGroups = 3;

  /// searchWorldbook 单次最多命中条目数与每条片段字符上限。
  static const int worldbookMaxHits = 3;
  static const int worldbookHitChars = 300;

  /// proposeMemory 提议文本上限:完整替换,但不得把输入撑爆。
  static const int maxProposedMemoryChars = 2000;

  static ({AgentSpec spec, MaintenanceStaging staging}) build({
    required LlmBackend backend,
    required String model,
    required Map<String, String> variables,
    required Map<String, VariableAccess> access,
    required List<Message> history,
    List<Message>? variableHistory,
    BackgroundFeatures features = const BackgroundFeatures(),
    int imageCount = 1,

    /// 会话是否启用生图:image 工具与契约段按它注册,而 [features] 只表示
    /// 本轮是否真生图(变量积压分批时本轮不生图)。二者分开让 image 轮与
    /// 变量轮的稳定前缀(工具面 + 契约)逐字一致,跨轮命中同一缓存段。
    required bool imageTools,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    RerunContext? rerunContext,
    bool variableInjection = false,
    bool nextSuggestions = false,
    required Future<List<Message>> Function({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    })
    readHistory,
    required HistorySearch searchHistory,

    /// 严格模式下读取待确认删除键(仅 validateStaged 展示用);null = 非严格。
    Future<Set<String>> Function()? pendingDeletions,

    /// 记忆工具(readMemory / proposeMemory):由调用方按「记忆进入上下文」
    /// 设置决定;关闭时后台与记忆完全隔离。
    bool memoryTools = false,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    void Function(AgentStepEvent)? onStep,
  }) {
    final staging = MaintenanceStaging(base: variables, access: access);
    final deletable = <String>{
      for (final e in access.entries)
        if (e.value == VariableAccess.full) e.key,
    };
    final readonly = <String>{
      for (final e in access.entries)
        if (e.value == VariableAccess.readonly) e.key,
    };
    // 已经在 system 可变段里呈现过的消息 seq:readHistory 新版页全命中时
    // 只回一句提示,不再重复整页正文。
    final shownSeqs = <int>{
      for (final m in history) m.seq,
      for (final m in variableHistory ?? history) m.seq,
    };
    // 按需参考检索:按会话数据/开关注册,不按轮次 —— image 轮这些内容虽已在
    // 锚定段里,工具仍是纯读、不会被自动调用;保持工具面跨轮一致才能共享
    // 稳定前缀缓存(生图轮与变量轮同集)。
    final backgroundEntries = [
      for (final e in worldbook)
        if (e.background && e.enabled) e,
    ];
    final worldbookLookup = backgroundEntries.isNotEmpty;
    final memoryText = memory?.trim() ?? '';
    final memoryLookup = memoryTools && memoryText.isNotEmpty;

    final registry = AgentToolRegistry();
    if (features.variables) {
      registry
        ..register(_readVariables(staging))
        ..register(_setVariables(staging))
        ..register(_removeVariables(staging));
    }
    if (features.variables && variableInjection) {
      registry.register(_setVariableInjection(staging));
    }
    if (nextSuggestions) {
      registry.register(_setNextSuggestions(staging));
    }
    registry
      ..register(_readHistory(readHistory, shownSeqs))
      ..register(_searchHistory(searchHistory));
    if (worldbookLookup) registry.register(_searchWorldbook(backgroundEntries));
    if (memoryLookup) registry.register(_readMemory(memoryText));
    if (memoryTools) registry.register(_proposeMemory(staging, memoryText));
    registry.register(
      _validateStaged(
        staging,
        image: features.image,
        imageCount: imageCount,
        variableInjection: features.variables && variableInjection,
        nextSuggestions: nextSuggestions,
        pendingDeletions: pendingDeletions,
      ),
    );
    // 工具总在(会话启用生图时),本轮是否可用由运行指令与执行器本地裁决:
    // 非生图轮调用被拒,不产生暂存。
    if (imageTools) {
      registry.register(
        _setImagePrompts(staging, imageCount, enabled: features.image),
      );
    }

    final prompt = _buildPrompt(
      variables: variables,
      history: history,
      variableHistory: variableHistory ?? history,
      features: features,
      imageTools: imageTools,
      imageGuide: imageGuide,
      memory: memory,
      character: character,
      worldbook: worldbook,
      deletable: deletable,
      readonly: readonly,
      rerunContext: rerunContext,
      variableInjection: features.variables && variableInjection,
      nextSuggestions: nextSuggestions,
      worldbookLookup: worldbookLookup,
      memoryLookup: memoryLookup,
      memoryTools: memoryTools,
    );
    // 轮次差异(是否生图/几张)只放首条 user 消息:它在稳定断点之后,
    // 字节变化不进缓存前缀。
    final roundNote = switch ((imageTools, features.image)) {
      (true, true) =>
        ' This round generates $imageCount image(s): stage exactly $imageCount scene '
            'description(s) via setImagePrompts.',
      (true, false) =>
        ' This round does not generate images; do not call setImagePrompts.',
      _ => '',
    };
    final spec = AgentSpec(
      backend: backend,
      model: model,
      systemPrompt: prompt.combined,
      stableSystemPart: prompt.stable,
      variableSystemPart: prompt.variable,
      // agent 多步重发稳定前缀:variables-only 轮也请求缓存(legacy 的
      // 「纯变量轮不缓存」是单发语义,多步下前缀跨步命中纯收益)。
      cacheStableSystem: true,
      initialUserMessage:
          'Maintain the state board for the conversation above using the tools, then call finish.'
          '$roundNote',
      registry: registry,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      softReminder: (step, count) => _softReminder(staging, step, count),
      onStep: onStep,
    );
    return (spec: spec, staging: staging);
  }

  // ---- 工具执行器:语义拒绝返回错误文本(合法步,自纠);schema 违规
  // throw AgentToolFailure(计入非法连击)。模型面向文本用英文,与提示词同语言。

  /// 只回暂存差异:当前变量板与权限档已经在 system 可变段里,整板再回一遍
  /// 是重复付费(老输出把整板 JSON 塞进每次取证步)。暂存可能被模型写成
  /// 大键/大值,结果按页 + 缩略回喂,保证 JSON 始终完整且低于内核硬帽。
  static AgentTool _readVariables(MaintenanceStaging staging) => AgentTool(
    tool: const LlmTool(
      name: 'readVariables',
      description:
          'Show what you have staged so far (updates and removals). The current variable board '
          'and permission tiers are already included in the context above. Updates are paged '
          'with offset/limit (default 20, max 50); over-long keys/values are abbreviated with '
          'an ellipsis so the JSON result always stays under the result cap. Local and free.',
      parameters: {
        'type': 'object',
        'properties': {
          'offset': {
            'type': 'integer',
            'description': 'Update page offset (default 0).',
          },
          'limit': {
            'type': 'integer',
            'description': 'Update page size, 1-50 (default 20).',
          },
        },
      },
    ),
    execute: (args) async {
      final rawOffset = args['offset'];
      final rawLimit = args['limit'];
      if (rawOffset != null && rawOffset is! int) {
        throw const AgentToolFailure('offset must be an integer.');
      }
      if (rawLimit != null && rawLimit is! int) {
        throw const AgentToolFailure('limit must be an integer.');
      }
      final requestedOffset = rawOffset as int? ?? 0;
      if (requestedOffset < 0) {
        return 'Error: offset must be >= 0. Nothing was read.';
      }
      final limit = ((rawLimit as int?) ?? readVariablesPageDefault)
          .clamp(1, readVariablesPageMax)
          .toInt();
      final all = staging.updates.entries.toList(growable: false);
      final offset = requestedOffset < all.length
          ? requestedOffset
          : all.length;
      var page = all.skip(offset).take(limit).toList();
      var abbreviated = false;

      String clipKey(String key) {
        if (key.length <= readVariableKeyChars) return key;
        abbreviated = true;
        return '${key.substring(0, safeStringEnd(key, readVariableKeyChars))}…';
      }

      String clipValue(String value) {
        if (value.length <= readVariableValueChars) return value;
        abbreviated = true;
        return '${value.substring(0, safeStringEnd(value, readVariableValueChars))}…';
      }

      Map<String, String> shownUpdates() {
        final out = <String, String>{};
        for (final update in page) {
          var key = clipKey(update.key);
          // 超长键截断后可能撞前缀:加序号保证每个暂存键都能露出。
          if (out.containsKey(key)) {
            var suffix = 2;
            while (out.containsKey('$key#$suffix')) {
              suffix++;
            }
            key = '$key#$suffix';
          }
          out[key] = clipValue(update.value);
        }
        return out;
      }

      Map<String, Object?> payload() => {
        'stagedUpdateCount': all.length,
        'stagedUpdates': shownUpdates(),
        'stagedRemovals': [for (final key in staging.removals) clipKey(key)],
        'removalsUsedThisRun': staging.everRemoved.length,
        'updatePage': {
          'offset': offset,
          'limit': limit,
          'nextOffset': offset + page.length < all.length
              ? offset + page.length
              : null,
        },
        if (abbreviated) 'abbreviated': true,
      };
      // 缩略后通常一次就够;页尾收缩让 nextOffset 指向未展示的首条更新。
      return encodeToolResultWithinBudget(payload, (excess) {
        if (page.length <= 1) return false;
        page = page.sublist(0, page.length - 1);
        return true;
      });
    },
  );

  static AgentTool _setVariables(
    MaintenanceStaging staging, {
    String? description,
  }) => AgentTool(
    tool: LlmTool(
      name: 'setVariables',
      description:
          description ??
          'Stage variable updates, applied atomically on finish. Stage only keys whose value '
              'CHANGED in variable_delta; new keys are allowed. Values must be scalars (string, '
              'finite number, boolean). Readonly keys cannot be updated.',
      parameters: const {
        'type': 'object',
        'properties': {
          'variables': {
            'type': 'object',
            'description': 'Exact key → new scalar value.',
            'additionalProperties': {
              'type': ['string', 'number', 'boolean'],
            },
          },
        },
        'required': ['variables'],
      },
    ),
    execute: (args) async {
      final raw = args['variables'];
      if (raw is! Map<String, Object?>) {
        throw const AgentToolFailure(
          'variables must be an object of key → scalar value.',
        );
      }
      // 整调用原子拒绝:先查 schema(空键/非标量),再查权限(readonly)。
      // 半批暂存会让模型以为被拒键也生效,与 legacy 整批拒绝同语义。
      final schemaBad = <String>[];
      for (final e in raw.entries) {
        if (e.key.trim().isEmpty) {
          schemaBad.add('(empty key)');
        } else if (e.value is! String && e.value is! num && e.value is! bool) {
          schemaBad.add('"${e.key}": non-scalar value');
        } else if (e.value is num && !(e.value as num).isFinite) {
          schemaBad.add('"${e.key}": non-finite number');
        }
      }
      if (schemaBad.isNotEmpty) {
        throw AgentToolFailure('invalid entries: ${schemaBad.join('; ')}.');
      }
      final denied = [
        for (final key in raw.keys)
          if (staging.access[key] == VariableAccess.readonly) '"$key"',
      ];
      if (denied.isNotEmpty) {
        return 'Error: readonly keys cannot be updated: ${denied.join(', ')}. '
            'Nothing was staged; retry without them.';
      }
      for (final e in raw.entries) {
        final value = e.value;
        staging.updates[e.key] = value is String ? value : value.toString();
        staging.removals.remove(e.key);
      }
      return 'Staged ${raw.length} update(s). They apply on finish.';
    },
  );

  static AgentTool _removeVariables(
    MaintenanceStaging staging, {
    String? description,
  }) => AgentTool(
    tool: LlmTool(
      name: 'removeVariables',
      description:
          description ??
          'Stage explicit removals of EXISTING deletable keys (at most 5 distinct keys per run). '
              'Remove only when variable_delta shows the fact ended, was left behind, or was '
              'permanently superseded. Never infer removal from a key being absent.',
      parameters: const {
        'type': 'object',
        'properties': {
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
            'description': 'Exact existing keys to remove.',
          },
        },
        'required': ['keys'],
      },
    ),
    execute: (args) async {
      final raw = args['keys'];
      if (raw is! List || raw.any((k) => k is! String)) {
        throw const AgentToolFailure(
          'keys must be an array of exact key strings.',
        );
      }
      final copy = staging.workingCopy;
      final accepted = <String>[];
      final errors = <String>[];
      for (final key in raw.cast<String>()) {
        if (staging.everRemoved.contains(key)) {
          // re-remove 免费(含 remove→set→remove):不重复计累计帽。
          if (!staging.removals.contains(key)) staging.removals.add(key);
          staging.updates.remove(key);
          accepted.add(key);
          continue;
        }
        if (!copy.containsKey(key)) {
          errors.add('"$key": not an existing key');
          continue;
        }
        final tier = staging.access[key] ?? VariableAccess.full;
        if (tier != VariableAccess.full) {
          errors.add('"$key": ${tier.name} keys cannot be removed');
          continue;
        }
        if (staging.everRemoved.length >= maxRemovalsPerRun) {
          errors.add(
            'removal limit reached ($maxRemovalsPerRun distinct keys per run)',
          );
          break;
        }
        staging.everRemoved.add(key);
        staging.removals.add(key);
        staging.updates.remove(key);
        accepted.add(key);
      }
      if (errors.isNotEmpty) {
        return 'Error: ${errors.join('; ')}. '
            '${accepted.isEmpty ? 'Nothing was staged.' : 'Staged: ${accepted.join(', ')}.'}';
      }
      return accepted.isEmpty
          ? 'No keys staged (empty list).'
          : 'Staged removal of ${accepted.length} key(s): ${accepted.join(', ')}. They apply on finish.';
    },
  );

  static AgentTool _readHistory(
    Future<List<Message>> Function({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    })
    readHistory,
    Set<int> shownSeqs,
  ) => AgentTool(
    pure: true,
    tool: const LlmTool(
      name: 'readHistory',
      description:
          'Page the session conversation (read-only, with seq numbers) to verify facts and '
          'their sources. Each page is at most 2000 chars. beforeSeq pages backwards (omit it '
          'for the newest page); aroundSeq returns a small window centered on one seq. Prefer '
          'searchHistory when you know a keyword.',
      parameters: {
        'type': 'object',
        'properties': {
          'beforeSeq': {
            'type': 'integer',
            'description':
                'Return messages with seq < beforeSeq. Omit for the newest page.',
          },
          'aroundSeq': {
            'type': 'integer',
            'description':
                'Return up to 2 messages before and after this seq, centered on it.',
          },
        },
      },
    ),
    execute: (args) async {
      final rawBefore = args['beforeSeq'];
      final rawAround = args['aroundSeq'];
      if (rawBefore != null && rawBefore is! int) {
        throw const AgentToolFailure('beforeSeq must be an integer.');
      }
      if (rawAround != null && rawAround is! int) {
        throw const AgentToolFailure('aroundSeq must be an integer.');
      }
      if (rawBefore != null && rawAround != null) {
        throw const AgentToolFailure('Pass beforeSeq or aroundSeq, not both.');
      }
      final aroundSeq = rawAround as int?;
      if (aroundSeq != null) {
        final beforeRows = await readHistory(
          beforeSeq: aroundSeq + 1,
          limit: readHistoryPageLimit,
        );
        final afterRows = await readHistory(
          afterSeq: aroundSeq,
          limit: aroundWindowAfter,
        );
        return _historyWindow(beforeRows, afterRows, aroundSeq);
      }
      final rows = await readHistory(
        beforeSeq: rawBefore as int?,
        limit: readHistoryPageLimit,
      );
      if (rows.isEmpty) {
        return 'No chat messages before this point.';
      }
      // 新版页与 system 可变段完全重合时不再重复整页正文:最常见的无效
      // 取证就是把 delta/参考窗原样翻一遍,白占一次工具结果。
      if (rawBefore == null && rows.every((m) => shownSeqs.contains(m.seq))) {
        return 'These messages are already included in your context above; no new content. '
            'Pass beforeSeq=${rows.first.seq} to read older messages, or use searchHistory.';
      }
      // 从最新往回保留 fit 字符帽的行(升序呈现);单条超帽截断保开头。
      final budget = readHistoryPageChars - 100;
      final lines = <String>[];
      var used = 0;
      var oldest = rows.last.seq;
      for (final m in rows.reversed) {
        var line = '[#${m.seq} ${m.role}] ${m.content}';
        if (line.length > budget) line = '${line.substring(0, budget)}…';
        if (lines.isNotEmpty && used + line.length + 1 > budget) break;
        lines.insert(0, line);
        used += line.length + 1;
        oldest = m.seq;
      }
      return '${lines.join('\n')}\n'
          '(Oldest seq on this page: $oldest. Pass beforeSeq=$oldest to read older messages.)';
    },
  );

  /// 邻近窗口:中心前至多 [aroundWindowBefore] 条 + 命中本身 + 中心后至多
  /// [aroundWindowAfter] 条;单行截断到 [aroundLineChars],把取证体积压在
  /// 一次工具结果的量级。
  static String _historyWindow(
    List<Message> before,
    List<Message> after,
    int centerSeq,
  ) {
    final merged = <int, Message>{
      for (final m in before) m.seq: m,
      for (final m in after) m.seq: m,
    };
    final rows = merged.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    final older = [
      for (final m in rows)
        if (m.seq < centerSeq) m,
    ];
    final window = <Message>[
      if (older.length > aroundWindowBefore)
        ...older.sublist(older.length - aroundWindowBefore)
      else
        ...older,
      for (final m in rows)
        if (m.seq == centerSeq) m,
      ...rows.where((m) => m.seq > centerSeq).take(aroundWindowAfter),
    ];
    if (window.isEmpty) {
      return 'No chat messages around seq $centerSeq.';
    }
    return '${window.map((m) => _windowLine(m, centerSeq)).join('\n')}\n'
        '(Window around seq $centerSeq. Use beforeSeq or searchHistory to continue.)';
  }

  static String _windowLine(Message m, int centerSeq) {
    var line = '[#${m.seq} ${m.role}] ${m.content}';
    if (line.length > aroundLineChars) {
      line = '${line.substring(0, aroundLineChars)}…';
    }
    return m.seq == centerSeq ? '$line (around target)' : line;
  }

  /// 取证搜索:命中行只带 seq/角色/压缩空白后的短片段,比翻页小一个量级。
  static AgentTool _searchHistory(HistorySearch searchHistory) => AgentTool(
    pure: true,
    tool: const LlmTool(
      name: 'searchHistory',
      description:
          'Search the session conversation for literal text (case-insensitive substring, not '
          'a regex). Returns at most 5 matches (seq, role, short snippet), newest first. '
          'Cheaper than paging readHistory when you know a keyword or name to verify.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Literal text to find.'},
        },
        'required': ['query'],
      },
    ),
    execute: (args) async {
      final raw = args['query'];
      if (raw is! String) {
        throw const AgentToolFailure('query must be a string.');
      }
      final query = raw.trim();
      if (query.isEmpty) {
        throw const AgentToolFailure('query must not be empty.');
      }
      if (query.length > searchQueryMaxChars) {
        throw const AgentToolFailure(
          'query must be at most $searchQueryMaxChars characters.',
        );
      }
      final hits = await searchHistory(query, limit: searchHistoryMaxHits);
      if (hits.isEmpty) {
        return 'No messages match "$query". Try a shorter or different keyword.';
      }
      final lines = [
        for (final h in hits) '[#${h.seq} ${h.role}] ${_snippet(h.content)}',
      ];
      final more = hits.length >= searchHistoryMaxHits
          ? '\n(Showing the $searchHistoryMaxHits newest matches; refine the query for older ones.)'
          : '';
      return '${lines.join('\n')}$more';
    },
  );

  static final _whitespaceRun = RegExp(r'\s+');

  static String _snippet(String text, {int maxChars = searchHitChars}) {
    final t = text.replaceAll(_whitespaceRun, ' ').trim();
    return t.length <= maxChars ? t : '${t.substring(0, maxChars)}…';
  }

  /// 用户选定的后台世界书条目:按字面量检索名称/关键词/正文,只回短片段。
  static AgentTool _searchWorldbook(List<WorldbookEntry> entries) => AgentTool(
    pure: true,
    tool: const LlmTool(
      name: 'searchWorldbook',
      description:
          'Search the user-selected background worldbook entries (read-only reference) for a '
          'literal keyword or name. Returns at most 3 entries with a short excerpt. Use it to '
          'keep names and established facts consistent; never use it as a source of variable '
          'changes.',
      parameters: {
        'type': 'object',
        'properties': {
          'query': {'type': 'string', 'description': 'Literal text to find.'},
        },
        'required': ['query'],
      },
    ),
    execute: (args) async {
      final raw = args['query'];
      if (raw is! String) {
        throw const AgentToolFailure('query must be a string.');
      }
      final query = raw.trim();
      if (query.isEmpty) {
        throw const AgentToolFailure('query must not be empty.');
      }
      final needle = query.toLowerCase();
      final hits = <WorldbookEntry>[];
      for (final entry in entries) {
        if (entry.name.toLowerCase().contains(needle) ||
            entry.content.toLowerCase().contains(needle) ||
            entry.keys.any((k) => k.toLowerCase().contains(needle))) {
          hits.add(entry);
          if (hits.length >= worldbookMaxHits) break;
        }
      }
      if (hits.isEmpty) {
        return 'No selected worldbook entry matches "$query".';
      }
      String label(WorldbookEntry e) => e.name.isNotEmpty
          ? e.name
          : (e.keys.isNotEmpty ? e.keys.first : '(unnamed)');
      return hits
          .map(
            (e) =>
                '[${label(e)}] ${_snippet(e.content, maxChars: worldbookHitChars)}',
          )
          .join('\n');
    },
  );

  /// 会话长期记忆只读副本(截断口径与 image 轮锚定段一致)。
  static AgentTool _readMemory(String memory) => AgentTool(
    pure: true,
    tool: const LlmTool(
      name: 'readMemory',
      description:
          'Read the session long-term memory (read-only reference) to keep durable facts '
          'consistent. It is never a source of variable changes.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    execute: (args) async =>
        backgroundTruncate(memory, BackgroundEngine.maxBackgroundMemoryChars),
  );

  /// 记忆提议:暂存整段替换文本,提交后只进状态面板给用户审阅,绝不落库。
  static AgentTool _proposeMemory(
    MaintenanceStaging staging,
    String currentMemory,
  ) => AgentTool(
    tool: const LlmTool(
      name: 'proposeMemory',
      description:
          'Stage a proposal for the USER to replace the session\'s long-term memory. It is '
          'never applied automatically: the user reviews it in the status panel. Use it only '
          'when the latest turns establish durable facts the current memory lacks or '
          'contradicts; provide the complete replacement text (at most '
          '$maxProposedMemoryChars characters) in the memory\'s language.',
      parameters: {
        'type': 'object',
        'properties': {
          'content': {
            'type': 'string',
            'description': 'Complete replacement memory text.',
          },
        },
        'required': ['content'],
      },
    ),
    execute: (args) async {
      final raw = args['content'];
      if (raw is! String) {
        throw const AgentToolFailure('content must be a string.');
      }
      final content = raw.trim();
      if (content.isEmpty) {
        throw const AgentToolFailure('content must not be empty.');
      }
      if (content.length > maxProposedMemoryChars) {
        throw const AgentToolFailure(
          'content must be at most $maxProposedMemoryChars characters.',
        );
      }
      if (content == currentMemory) {
        return 'Error: the proposal matches the current memory; nothing was staged.';
      }
      staging.memoryProposal = content;
      return 'Staged a memory proposal for user review. It is not applied automatically.';
    },
  );

  /// 提交前 dry-run:只读暂存态与最终板,零网络、零落库。用一次缓存价步
  /// 挡住「finish 后才发现注入键被丢/生图条数不对/重复键」的整轮重跑。
  static AgentTool _validateStaged(
    MaintenanceStaging staging, {
    required bool image,
    required int imageCount,
    bool variableInjection = false,
    bool nextSuggestions = false,
    Future<Set<String>> Function()? pendingDeletions,

    /// true = 报整板的近义重复键(审计的职责);false = 只报本轮暂存更新
    /// 撞上的重复组,避免维护轮被引导去合并既有别名。
    bool duplicateScopeAll = false,
  }) => AgentTool(
    tool: LlmTool(
      name: 'validateStaged',
      description:
          'Dry-run the finish commit without changing anything: reports staged counts, '
          'injection keys that would be dropped, image prompt count issues, '
          '${duplicateScopeAll ? 'near-duplicate keys on the board' : 'near-duplicate keys introduced by your staged updates'}, '
          'and strict-mode deletion proposals already awaiting confirmation. Local and free.',
      parameters: const {'type': 'object', 'properties': {}},
    ),
    execute: (args) async {
      // 严格删除模式下暂存删除只生成待确认提案,提交后键仍留在板上 —— 计算
      // 注入可见性必须按「不真删」的板,否则会把仍会注入的键误报成将丢弃。
      final strictDeletions = pendingDeletions != null;
      final finalBoard = strictDeletions
          ? (<String, String>{...staging.base, ...staging.updates})
          : staging.workingCopy;
      final issues = <String>[];
      final notes = <String>[];

      final missing = [
        for (final key in staging.injectionKeys ?? const <String>[])
          if (!finalBoard.containsKey(key)) key,
      ];
      if (missing.isNotEmpty) {
        issues.add(
          'injection key(s) missing from the final board (will be dropped): '
          '${_keyList(missing)}.',
        );
      }
      if (strictDeletions) {
        final pendingInjection = [
          for (final key in staging.injectionKeys ?? const <String>[])
            if (staging.base.containsKey(key) && staging.removals.contains(key))
              key,
        ];
        if (pendingInjection.isNotEmpty) {
          notes.add(
            'staged deletion(s) await user confirmation and will still be '
            'injected this round: ${_keyList(pendingInjection)}.',
          );
        }
      }
      if (image &&
          staging.imagePrompts != null &&
          staging.imagePrompts!.length != imageCount) {
        issues.add(
          'image prompts: staged ${staging.imagePrompts!.length}, '
          'this round expects exactly $imageCount.',
        );
      }
      final duplicates = _duplicateKeyGroups(
        finalBoard.keys,
        focus: duplicateScopeAll ? null : staging.updates.keys.toSet(),
      );
      if (duplicates.isNotEmpty) {
        issues.add(
          'near-duplicate keys (pick one canonical key): '
          '${duplicates.map((g) => g.map((k) => '"$k"').join(' / ')).join('; ')}.',
        );
      }
      final pendingReader = pendingDeletions;
      if (pendingReader != null) {
        final pending = (await pendingReader()).toList()..sort();
        if (pending.isNotEmpty) {
          notes.add('pending user confirmation: ${_keyList(pending)}.');
          final overlap = [
            for (final key in staging.removals)
              if (pending.contains(key)) key,
          ];
          if (overlap.isNotEmpty) {
            issues.add(
              'already pending confirmation (restaging spends the removal cap): '
              '${_keyList(overlap)}.',
            );
          }
        }
      }

      final counts = <String>[
        '${staging.updates.length} update(s)',
        '${staging.removals.length} removal(s)',
        if (image)
          '${staging.imagePrompts?.length ?? 0}/$imageCount image prompt(s)',
        if (variableInjection)
          '${staging.injectionKeys?.length ?? 0} injection key(s)',
        if (nextSuggestions)
          '${staging.nextSuggestions?.length ?? 0} suggestion(s)',
      ].join(', ');
      final lines = <String>['Dry run (nothing committed): $counts.'];
      for (final note in notes) {
        lines.add('Note: $note');
      }
      if (issues.isEmpty) {
        lines.add('Ready to commit - call finish.');
      } else {
        for (final issue in issues) {
          lines.add('Issue: $issue');
        }
        lines.add('Fix these or accept the drops, then call finish.');
      }
      return lines.join('\n');
    },
  );

  static final _keySeparatorRun = RegExp(r'[\s_-]+');

  /// 归一化后的近义键分组:大小写/空白/下划线/连字符折叠后相同的键归为一组,
  /// 只报 ≥2 个原始键的组,最多 [maxDuplicateKeyGroups] 组。[focus] 非 null
  /// 时只保留包含其中键的组(维护轮只看本轮暂存造成的冲突)。
  static List<List<String>> _duplicateKeyGroups(
    Iterable<String> keys, {
    Set<String>? focus,
  }) {
    final groups = <String, List<String>>{};
    for (final key in keys) {
      final normalized = key
          .toLowerCase()
          .replaceAll(_keySeparatorRun, ' ')
          .trim();
      if (normalized.isEmpty) continue;
      groups.putIfAbsent(normalized, () => []).add(key);
    }
    final out = [
      for (final group in groups.values)
        if (group.length > 1 && (focus == null || group.any(focus.contains)))
          (group.toList()..sort()),
    ];
    out.sort((a, b) {
      final bySize = b.length.compareTo(a.length);
      return bySize != 0 ? bySize : a.first.compareTo(b.first);
    });
    return out.take(maxDuplicateKeyGroups).toList();
  }

  static String _keyList(Iterable<String> keys) {
    final list = keys.toList();
    if (list.length <= 6) return list.join(', ');
    return '${list.take(6).join(', ')} ... (+${list.length - 6})';
  }

  /// 描述与 schema 不嵌图片数量(数量由首条 user 消息给出):工具定义属于
  /// 稳定前缀,改「每次生图数量」不应让整段缓存失效。[enabled] 是本轮是否
  /// 真生图 —— 非生图轮工具照样注册(工具面跨轮一致),调用被本地拒绝。
  static AgentTool _setImagePrompts(
    MaintenanceStaging staging,
    int imageCount, {
    required bool enabled,
  }) => AgentTool(
    tool: const LlmTool(
      name: 'setImagePrompts',
      description:
          'Stage the scene descriptions for this round\'s image generation when the run '
          'instruction says this round generates images: exactly the stated number of English '
          'NovelAI tag string(s) per the image_guide, each a distinct framing of the SAME '
          'current scene. Replaces any previously staged prompts; a call with any other count '
          'is rejected without staging (fix the count and call again). Calls on a round that '
          'does not generate images are rejected.',
      parameters: {
        'type': 'object',
        'properties': {
          'prompts': {
            'type': 'array',
            'items': {'type': 'string'},
            'minItems': 1,
          },
        },
        'required': ['prompts'],
      },
    ),
    execute: (args) async {
      if (!enabled) {
        return 'Error: this round does not generate images; nothing was staged.';
      }
      final raw = args['prompts'];
      if (raw is! List || raw.any((p) => p is! String)) {
        throw const AgentToolFailure(
          'prompts must be an array of tag strings.',
        );
      }
      final prompts = raw.cast<String>();
      if (prompts.length != imageCount) {
        // 数量是本轮契约的一部分:少于目标时不能静默消费生图机会,返回
        // 语义拒绝让模型补齐后重发(语义拒绝不计非法连击、不动暂存)。
        return 'Error: this round generates exactly $imageCount image prompt(s); '
            'got ${prompts.length}. Stage exactly $imageCount distinct prompts in '
            'one call. Nothing was staged.';
      }
      if (prompts.any((p) => p.trim().isEmpty)) {
        throw const AgentToolFailure('prompts must be non-empty tag strings.');
      }
      staging.imagePrompts = [for (final p in prompts) p.trim()];
      return 'Staged ${staging.imagePrompts!.length} image prompt(s). They generate on finish.';
    },
  );

  /// 变量注入选择:只挑键,值在提交后按最终变量板解析(先改变量再选键)。
  static AgentTool _setVariableInjection(
    MaintenanceStaging staging,
  ) => AgentTool(
    tool: const LlmTool(
      name: 'setVariableInjection',
      description:
          'Stage the exact variable keys to carry into the main writer as a system-reminder '
          'immediately before the user\'s next message. Keys must exist in the working copy '
          '(staged updates included, staged removals excluded). At most $maxInjectionKeys keys; '
          'replaces any previous selection; an empty list clears it. Values are read from the '
          'final board after all staged changes are applied.',
      parameters: {
        'type': 'object',
        'properties': {
          'keys': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': maxInjectionKeys,
            'description': 'Exact existing keys to inject, in display order.',
          },
        },
        'required': ['keys'],
      },
    ),
    execute: (args) async {
      final raw = args['keys'];
      if (raw is! List || raw.any((k) => k is! String)) {
        throw const AgentToolFailure(
          'keys must be an array of exact key strings.',
        );
      }
      final copy = staging.workingCopy;
      final keys = <String>[];
      final errors = <String>[];
      for (final key in raw.cast<String>()) {
        if (key.trim().isEmpty) {
          errors.add('(empty key)');
          continue;
        }
        if (!copy.containsKey(key)) {
          errors.add('"$key": not an existing key');
          continue;
        }
        if (!keys.contains(key)) keys.add(key);
      }
      if (keys.length > maxInjectionKeys) {
        return 'Error: at most $maxInjectionKeys keys can be injected; nothing was staged.';
      }
      if (errors.isNotEmpty) {
        return 'Error: ${errors.join('; ')}. '
            'Nothing was staged; retry with exact existing keys.';
      }
      staging.injectionKeys = keys;
      return keys.isEmpty
          ? 'Cleared the variable injection selection.'
          : 'Staged ${keys.length} variable key(s) for injection: ${keys.join(', ')}. '
                'Their values apply after staged changes are committed.';
    },
  );

  /// 下一步建议:用户口吻、可直接发送的完整发言;末次调用整组替换。
  static AgentTool _setNextSuggestions(MaintenanceStaging staging) => AgentTool(
    tool: const LlmTool(
      name: 'setNextSuggestions',
      description:
          'Optionally stage up to $maxNextSuggestions next-step suggestions for the user. Each '
          'must be a complete, ready-to-send message in the USER\'s own voice (first person), '
          'grounded in the latest conversation: no narration, no meta commentary, no slash '
          'commands, at most $maxNextSuggestionChars characters. Replaces any previous '
          'suggestions; an empty list clears them.',
      parameters: {
        'type': 'object',
        'properties': {
          'suggestions': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': maxNextSuggestions,
            'description':
                'Distinct user-voice messages, ordered by usefulness; an empty list clears '
                'previously staged suggestions.',
          },
        },
        'required': ['suggestions'],
      },
    ),
    execute: (args) async {
      final raw = args['suggestions'];
      // 空数组是与 setVariableInjection 一致的显式清空语义,不是非法调用:
      // 三次清空若计入非法连击,会把整轮合法暂存一起丢掉。
      if (raw is! List || raw.length > maxNextSuggestions) {
        throw const AgentToolFailure(
          'suggestions must be an array of at most $maxNextSuggestions strings.',
        );
      }
      final out = <String>[];
      for (final entry in raw) {
        if (entry is! String) {
          throw const AgentToolFailure('suggestions must be strings.');
        }
        final text = entry.trim();
        if (text.isEmpty) {
          throw const AgentToolFailure('suggestions must not be empty.');
        }
        if (text.length > maxNextSuggestionChars) {
          throw const AgentToolFailure(
            'each suggestion must be at most $maxNextSuggestionChars characters.',
          );
        }
        if (text.startsWith('/')) {
          throw const AgentToolFailure('suggestions must not start with "/".');
        }
        if (out.contains(text)) {
          throw const AgentToolFailure('suggestions must be distinct.');
        }
        out.add(text);
      }
      staging.nextSuggestions = out;
      return out.isEmpty
          ? 'Cleared the next-step suggestions.'
          : 'Staged ${out.length} next-step suggestion(s) for the user.';
    },
  );

  // ---- 提示词:数据段与 legacy 逐字同构(共享 builder),契约改工具措辞。

  static ({String stable, String variable, String combined}) _buildPrompt({
    required Map<String, String> variables,
    required List<Message> history,
    required List<Message> variableHistory,
    required BackgroundFeatures features,

    /// 会话启用生图(见 [MaintenanceProfile.build] 的同名参数):契约只按它
    /// 裁剪,图片数量与轮次差异由首条 user 消息给出,稳定段因此逐轮字节一致。
    required bool imageTools,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    Set<String> deletable = const {},
    Set<String> readonly = const {},
    RerunContext? rerunContext,
    bool variableInjection = false,
    bool nextSuggestions = false,
    bool worldbookLookup = false,
    bool memoryLookup = false,
    bool memoryTools = false,
  }) {
    final stageTools = [
      if (features.variables) 'setVariables / removeVariables',
      if (imageTools) 'setImagePrompts',
      if (variableInjection) 'setVariableInjection',
      if (nextSuggestions) 'setNextSuggestions',
    ].join(' / ');
    final verifyTools = features.variables
        ? 'readVariables / readHistory / searchHistory'
        : 'readHistory / searchHistory';
    final instruction = StringBuffer()
      ..writeln(
        'You are the background state-maintenance agent for a roleplay session. After each '
        'assistant reply you inspect the latest conversation and maintain the session\'s durable '
        'state by CALLING TOOLS. You are not a chat participant: never write prose, never reply '
        'to the user, never explain.',
      )
      ..writeln()
      ..writeln('# Tool contract (hard rules)')
      ..writeln(
        '- Act only via tool calls. Workflow: stage changes with $stageTools, verify with '
        '$verifyTools, then call finish to commit and end the run.',
      )
      ..writeln(
        '- Changes are staged in memory and applied atomically on finish; a failed or cancelled '
        'run discards everything. Do not restate unchanged state.',
      )
      ..writeln(
        '- searchHistory finds exact mentions; readHistory pages or reads a small window around '
        'a seq. validateStaged dry-runs the commit; call it before finish once you have staged '
        'changes.',
      );
    final lookupNames = [
      if (worldbookLookup) 'searchWorldbook',
      if (memoryLookup) 'readMemory',
    ];
    if (lookupNames.isNotEmpty) {
      instruction.writeln(
        '- ${lookupNames.join(' / ')} are read-only lookups of user-selected lore and the '
        'long-term memory; never treat them as a source of variable changes.',
      );
    }
    if (memoryTools) {
      instruction.writeln(
        '- proposeMemory stages a complete memory replacement for the USER to review; it is '
        'never applied automatically. Propose only when durable facts are clearly missing or '
        'contradicted, and keep the existing memory\'s language and scope.',
      );
    }
    instruction
      ..writeln()
      ..writeln('# How to read the context')
      ..writeln(
        '- recent_conversation is read-only context and the ONLY source of truth for the current '
        'image scene; it is never a source of variable updates.',
      )
      ..writeln(
        '- Any memory, character, worldbook_background or image_guide section below is durable, '
        'read-only background: never contradict it, never copy it into your output, never invent '
        'facts that fight it. Sections may be absent — work with what is present.',
      )
      ..writeln();
    if (features.variables) {
      instruction
        ..writeln('# variables')
        ..writeln(
          '- Variables are the session\'s durable state board: short key-value pairs for facts '
          'that persist and change across the story (location, time, condition, goals, '
          'relationships, possessions, ongoing effects). Not a per-scene summary.',
        )
        ..writeln(
          '- variable_delta holds this run\'s unprocessed turns and is the ONLY source of variable '
          'changes; never replay old changes from recent_conversation.',
        )
        ..writeln(
          '- Stage only keys whose value CHANGED in variable_delta via setVariables.',
        )
        ..writeln(
          '- Create new keys when variable_delta establishes a durable fact of this kind that no '
          'existing key covers: keep the key short and stable, reuse that exact key in later '
          'runs, and prefer updating an existing key over creating a near-duplicate or synonym. '
          'Do not track transient scene details that will not matter again.',
        )
        ..writeln(
          '- Preserve existing keys exactly, including whitespace; keys must not be empty or '
          'whitespace-only. Values are scalars: strings, finite numbers or booleans; never null, '
          'objects or arrays.',
        )
        ..writeln(
          '- Delete only via removeVariables with the key\'s EXACT existing name, and only when '
          'variable_delta shows the fact has ended, been left behind, or been permanently '
          'superseded. Never delete because a key is absent from variable_delta or the board '
          'looks cluttered; if the key still describes state, update it to a neutral value '
          'instead.',
        )
        ..writeln(
          '- variable_access governs EXISTING keys: only deletable keys may be removed; readonly '
          'keys must never be updated or removed; all other existing keys may be updated but '
          'never removed. New keys are unrestricted.',
        )
        ..writeln(
          '- At most $maxRemovalsPerRun distinct removals per run. A key must never end up both '
          'updated and removed: the last action wins.',
        )
        ..writeln(
          '- readVariables shows only what you have staged; the current board and permissions are '
          'already above. readHistory pages the conversation and searchHistory finds exact '
          'mentions to verify facts and their sources.',
        )
        ..writeln();
    }
    if (imageTools) {
      instruction
        ..writeln('# image')
        ..writeln(
          '- When the run instruction says this round generates images, stage the stated number '
          'of scene descriptions via setImagePrompts — never generic, never stale. Describe the '
          'CURRENT scene from recent_conversation: who is present, where, the action, lighting '
          'and mood.',
        )
        ..writeln(
          '- Reproduce each character\'s established appearance EXACTLY as pinned by the '
          'image_guide (and the character / memory sections when present); vary only '
          'scene-specific pose, expression, action and mood.',
        )
        ..writeln(
          '- Write each as the English NovelAI tag format defined in the image_guide: one '
          'comma-separated tag string, not a sentence.',
        )
        ..writeln(
          '- For more than one image, stage that many DIFFERENT tag strings: distinct framings '
          '(shot size / angle / composition / focus / mood) of the SAME current scene, mutually '
          'consistent and each independently usable.',
        )
        ..writeln();
    }
    if (variableInjection) {
      instruction
        ..writeln('# variable injection')
        ..writeln(
          '- Optionally stage up to $maxInjectionKeys exact keys with setVariableInjection when a '
          'few variables should shape the user\'s next turn. They reach the main writer as a '
          'system-reminder immediately before the next user message.',
        )
        ..writeln(
          '- Keys must exist in the working copy; staged removals win and missing keys are '
          'dropped. Values come from the FINAL board after all staged changes apply — stage '
          'variable changes first, never guess a value here.',
        )
        ..writeln(
          '- Select only what the next reply actually needs; an empty list clears the selection. '
          'Never copy injected variables into your output.',
        )
        ..writeln();
    }
    if (nextSuggestions) {
      instruction
        ..writeln('# next-step suggestions')
        ..writeln(
          '- Optionally stage 1..$maxNextSuggestions suggestions with setNextSuggestions when '
          'useful continuations are clear from the latest turns. An empty list clears any '
          'previously staged suggestions.',
        )
        ..writeln(
          '- Each suggestion is a complete, ready-to-send message in the USER\'s voice (first '
          'person), grounded in the latest conversation: at most $maxNextSuggestionChars '
          'characters, no narration, no meta commentary, no slash commands.',
        )
        ..writeln(
          '- The user sees them as tappable options and may ignore them; stage none when the scene '
          'does not call for a suggestion.',
        )
        ..writeln();
    }

    final stableSections = <String>[
      backgroundTag(
        'background_task',
        'Background maintenance contract: the tool protocol and rules for this run.',
        instruction.toString().trimRight(),
      ),
    ];
    if (features.image) {
      stableSections.addAll(
        imageAnchorSections(
          imageGuide: imageGuide,
          character: character,
          memory: memory,
          worldbook: worldbook,
          memoryChars: BackgroundEngine.maxBackgroundMemoryChars,
          characterChars: BackgroundEngine.maxBackgroundCharacterChars,
        ),
      );
    }
    final variableSections = <String>[transcriptSection(history)];
    if (features.variables) {
      variableSections
        ..add(variableDeltaSection(variableHistory))
        ..add(variablesSection(variables))
        ..add(variableAccessSection(deletable, readonly));
    }
    final rerun = rerunContext;
    if (rerun != null) {
      variableSections.add(
        backgroundTag(
          'rerun_instruction',
          'Rerun context for this run (user-triggered; final instruction, applied after the context above).',
          _rerunInstruction(rerun, features),
        ),
      );
    }
    final stable = stableSections.join('\n\n');
    final variable = variableSections.join('\n\n');
    return (
      stable: stable,
      variable: variable,
      combined: variable.isEmpty ? stable : '$stable\n\n$variable',
    );
  }

  /// 重跑说明(工具措辞):数据与截断上限沿 legacy(方向 ≤500、上一轮描述
  /// ≤6 条 ×500),契约引用改工具 —— legacy 版引用「output shape/valid JSON」,
  /// 不能直接复用。
  static String _rerunInstruction(
    RerunContext context,
    BackgroundFeatures features,
  ) {
    final lines = <String>[
      'This run is a RERUN of the previous background maintenance for the same conversation '
          'window, requested by the user. The previous run\'s choices are not final: re-evaluate '
          'the conversation above and stage a fresh, complete set of changes with the tools. The '
          'variables shown above are the current state (usually including the previous run\'s '
          'applied changes); stage only what this rerun changes.',
    ];
    final direction = context.direction?.trim() ?? '';
    if (direction.isNotEmpty) {
      lines
        ..add('')
        ..add('The user requested this change in direction:')
        ..add(
          backgroundTruncate(
            direction,
            BackgroundEngine.maxRerunDirectionChars,
          ),
        )
        ..add('')
        ..add(
          'Apply it to the changes you stage: when it implies durable state changes, stage matching '
          'variable updates (new keys are allowed; permissions still apply); when it implies a '
          'visual change, reflect it in the new scene description while keeping the fixed '
          'appearance and style pinned by the image_guide. It never overrides the hard rules '
          'above — variable permissions and the image tag format stay mandatory — and it does '
          'not turn the recent_conversation section into a variable source.',
        );
    }
    final previous = <String>[
      for (final prompt in context.previousImagePrompts)
        if (prompt.trim().isNotEmpty)
          backgroundTruncate(
            prompt,
            BackgroundEngine.maxRerunPreviousImageChars,
          ),
    ].take(BackgroundEngine.maxRerunPreviousImages).toList();
    if (features.image && previous.isNotEmpty) {
      lines
        ..add('')
        ..add(
          'Image descriptions produced by the previous maintenance (reference only — the '
          'previous output, not established facts; this run replaces those images):',
        );
      for (var i = 0; i < previous.length; i++) {
        lines.add('${i + 1}. ${previous[i]}');
      }
      lines.add(
        'Use them as the baseline to revise rather than text to copy; keep the established scene '
        'facts and image_guide constraints.',
      );
    }
    return lines.join('\n');
  }

  /// 软提醒:逐级升级语气 + 暂存摘要,促 finish(无硬帽,决策③)。
  static String _softReminder(MaintenanceStaging staging, int step, int count) {
    final urgency = switch (count) {
      1 => 'Please wrap up soon.',
      2 => 'You should finish now.',
      _ => 'Finish immediately with the changes staged so far.',
    };
    return 'Step $step: $urgency Staged so far: ${staging.updates.length} update(s), '
        '${staging.removals.length} removal(s), '
        '${staging.imagePrompts?.length ?? 0} image prompt(s), '
        '${staging.injectionKeys?.length ?? 0} injection key(s), '
        '${staging.nextSuggestions?.length ?? 0} suggestion(s), '
        '${staging.memoryProposal != null ? 1 : 0} memory proposal(s). Call finish to commit.';
  }
}

/// 审计 profile(hybrid 周期):全量变量板 + 权限 + 宽历史窗取证,工具面去掉
/// setImagePrompts(审计不生图)。契约与维护刻意不同 —— 维护只从 variable_delta
/// 取变化,审计可据宽窗合并近义键/修剪陈旧事实/修正矛盾,保守优先。复用维护的
/// 暂存态与工具执行器(同库私有静态成员),提交仍走原 compareAndApply。
class AuditProfile {
  /// 触发间隔:每 N 个成功变量轮(变量真应用)跑一次审计。计数器 per-session
  /// 内存态,切会话/重启清零;成败重置,让位/取消不重置(稍后重试)。
  static const int auditInterval = 5;

  /// 审计宽历史窗条数(取证上下文,比维护的参考窗宽)。
  static const int maxAuditHistoryMessages = 30;

  static const String _kAuditSetDescription =
      'Stage variable board corrections, applied atomically on finish. Merge near-duplicate or '
      'synonym keys into one canonical key, fix values contradicted by the evidence, and '
      'consolidate stale state. Base every correction on the audit_history evidence, readHistory '
      'and searchHistory, never on guesswork. Values must be scalars (string, finite number, '
      'boolean). Readonly keys cannot be updated.';

  static const String _kAuditRemoveDescription =
      'Stage explicit removals of EXISTING deletable keys (at most 5 distinct keys per run). '
      'Remove an alias after merging it into a canonical key, or prune a fact the audit_history '
      'clearly shows has ended, been left behind, or been permanently superseded. Be conservative: '
      'never remove a key merely because the board looks cluttered or its source is not found. '
      'Never infer removal from a key being absent.';

  static ({AgentSpec spec, MaintenanceStaging staging}) build({
    required LlmBackend backend,
    required String model,
    required Map<String, String> variables,
    required Map<String, VariableAccess> access,
    required List<Message> history,
    required Future<List<Message>> Function({
      int? beforeSeq,
      int? afterSeq,
      required int limit,
    })
    readHistory,
    required HistorySearch searchHistory,
    Future<Set<String>> Function()? pendingDeletions,
    double temperature = LlmModelEntry.defaultTemperature,
    int? maxTokens,
    ReasoningLevel reasoningLevel = ReasoningLevel.off,
    bool Function()? shouldCancel,
    Future<void>? cancelSignal,
    void Function(AgentStepEvent)? onStep,
  }) {
    final staging = MaintenanceStaging(base: variables, access: access);
    final deletable = <String>{
      for (final e in access.entries)
        if (e.value == VariableAccess.full) e.key,
    };
    final readonly = <String>{
      for (final e in access.entries)
        if (e.value == VariableAccess.readonly) e.key,
    };
    final shownSeqs = <int>{for (final m in history) m.seq};

    // 工具面:读/改/删/翻页/搜索/校验六件,无 setImagePrompts(审计不生图)。
    final registry = AgentToolRegistry()
      ..register(MaintenanceProfile._readVariables(staging))
      ..register(
        MaintenanceProfile._setVariables(
          staging,
          description: _kAuditSetDescription,
        ),
      )
      ..register(
        MaintenanceProfile._removeVariables(
          staging,
          description: _kAuditRemoveDescription,
        ),
      )
      ..register(MaintenanceProfile._readHistory(readHistory, shownSeqs))
      ..register(MaintenanceProfile._searchHistory(searchHistory))
      ..register(
        MaintenanceProfile._validateStaged(
          staging,
          image: false,
          imageCount: 1,
          pendingDeletions: pendingDeletions,
          duplicateScopeAll: true,
        ),
      );

    final prompt = _buildAuditPrompt(
      variables: variables,
      history: history,
      deletable: deletable,
      readonly: readonly,
    );
    final spec = AgentSpec(
      backend: backend,
      model: model,
      systemPrompt: prompt.combined,
      stableSystemPart: prompt.stable,
      variableSystemPart: prompt.variable,
      cacheStableSystem: true,
      initialUserMessage:
          'Audit the state board for the conversation above using the tools, then call finish.',
      registry: registry,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
      shouldCancel: shouldCancel,
      cancelSignal: cancelSignal,
      softReminder: (step, count) => _auditSoftReminder(staging, step, count),
      onStep: onStep,
    );
    return (spec: spec, staging: staging);
  }

  static ({String stable, String variable, String combined}) _buildAuditPrompt({
    required Map<String, String> variables,
    required List<Message> history,
    required Set<String> deletable,
    required Set<String> readonly,
  }) {
    final instruction = StringBuffer()
      ..writeln(
        'You are the background variable-board auditor for a roleplay session. Periodically you '
        'inspect the whole state board against the recent conversation and tidy it by CALLING '
        'TOOLS. You are not a chat participant: never write prose, never reply to the user, '
        'never explain.',
      )
      ..writeln()
      ..writeln('# Tool contract (hard rules)')
      ..writeln(
        '- Act only via tool calls. Workflow: stage corrections with setVariables / '
        'removeVariables, verify with readVariables / readHistory / searchHistory, then call '
        'finish to commit and end the run.',
      )
      ..writeln(
        '- Changes are staged in memory and applied atomically on finish; a failed or cancelled '
        'run discards everything. Do not restate unchanged state.',
      )
      ..writeln()
      ..writeln('# How to read the context')
      ..writeln(
        '- audit_history is a wide window of recent conversation turns and your EVIDENCE for '
        'auditing the board. Unlike per-turn maintenance, you MAY correct the board based on '
        'this wider evidence.',
      )
      ..writeln(
        '- The variables section is the current full board; variable_access lists permissions '
        'for existing keys. Both are read-only inputs.',
      )
      ..writeln()
      ..writeln('# Audit goals')
      ..writeln(
        '- Merge near-duplicate or synonym keys: pick one canonical key, setVariables it to the '
        'consolidated value, and removeVariables the aliases (each alias removal counts toward '
        'the limit).',
      )
      ..writeln(
        '- Prune facts that have ended, been left behind, or been permanently superseded, when '
        'the evidence clearly shows it.',
      )
      ..writeln('- Fix values that contradict the conversation evidence.')
      ..writeln(
        '- validateStaged dry-runs the commit and lists near-duplicate key candidates; use it '
        'before finish to confirm the consolidation is complete.',
      )
      ..writeln()
      ..writeln('# Conservative first')
      ..writeln(
        '- When unsure, DO NOT touch a key. Never remove or rewrite a key merely because the '
        'board looks cluttered or you cannot find its source; absence of evidence is not '
        'evidence of absence.',
      )
      ..writeln(
        '- Prefer leaving a still-meaningful key intact (or updating it to a neutral value) over '
        'deleting it. Do not invent new facts; new keys are allowed only when consolidating '
        'existing state, not for transient scene details.',
      )
      ..writeln()
      ..writeln('# Hard limits and permissions')
      ..writeln(
        '- Preserve existing keys exactly, including whitespace; keys must not be empty or '
        'whitespace-only. Values are scalars: strings, finite numbers or booleans; never null, '
        'objects or arrays.',
      )
      ..writeln(
        '- Delete only via removeVariables with the key\'s EXACT existing name. Only keys '
        'listed under variable_access.deletable may be removed; readonly keys must never be '
        'updated or removed; all other existing keys may be updated but never removed.',
      )
      ..writeln(
        '- At most ${MaintenanceProfile.maxRemovalsPerRun} distinct removals per run. A key must '
        'never end up both updated and removed: the last action wins.',
      )
      ..writeln(
        '- In strict confirmation mode your removals become proposals the user must approve; '
        'stage them the same way.',
      )
      ..writeln(
        '- readVariables shows only what you have staged; the current board and permissions are '
        'already above. readHistory pages the conversation and searchHistory finds exact '
        'mentions to verify facts and their sources.',
      );

    final stable = backgroundTag(
      'background_audit',
      'Variable board audit contract: the tool protocol and rules for this run.',
      instruction.toString().trimRight(),
    );
    final variable = [
      auditHistorySection(history),
      variablesSection(variables),
      variableAccessSection(deletable, readonly),
    ].join('\n\n');
    return (
      stable: stable,
      variable: variable,
      combined: '$stable\n\n$variable',
    );
  }

  /// 审计软提醒:逐级升级 + 暂存摘要(无生图,故不计 image prompt)。
  static String _auditSoftReminder(
    MaintenanceStaging staging,
    int step,
    int count,
  ) {
    final urgency = switch (count) {
      1 => 'Please wrap up soon.',
      2 => 'You should finish now.',
      _ => 'Finish immediately with the changes staged so far.',
    };
    return 'Step $step: $urgency Staged so far: ${staging.updates.length} update(s), '
        '${staging.removals.length} removal(s). Call finish to commit.';
  }
}
