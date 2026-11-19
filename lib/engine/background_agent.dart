/// 后台维护 profile(agentic 模式):工具契约提示词 + 工具面 + 内存暂存态。
/// 循环中一切写只改暂存;finish 后由编排器走原 compareAndApply 一次原子
/// 提交(权限事务内终裁/≤5 删除/回收站/严格提案零改)。中途失败/取消/护栏
/// 触发 → 暂存全丢弃。数据段与 legacy 单发逐字同构(background_prompt),
/// 契约文本改工具措辞;审计 profile(P4)将复用本文件的内核接线。
library;

import 'dart:convert';
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

  static ({AgentSpec spec, MaintenanceStaging staging}) build({
    required LlmBackend backend,
    required String model,
    required Map<String, String> variables,
    required Map<String, VariableAccess> access,
    required List<Message> history,
    List<Message>? variableHistory,
    BackgroundFeatures features = const BackgroundFeatures(),
    int imageCount = 1,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    RerunContext? rerunContext,
    required Future<List<Message>> Function({int? beforeSeq, required int limit})
        readHistory,
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

    final registry = AgentToolRegistry();
    if (features.variables) {
      registry
        ..register(_readVariables(staging, deletable, readonly))
        ..register(_setVariables(staging))
        ..register(_removeVariables(staging));
    }
    registry.register(_readHistory(readHistory));
    if (features.image) {
      registry.register(_setImagePrompts(staging, imageCount));
    }

    final prompt = _buildPrompt(
      variables: variables,
      history: history,
      variableHistory: variableHistory ?? history,
      features: features,
      imageCount: imageCount,
      imageGuide: imageGuide,
      memory: memory,
      character: character,
      worldbook: worldbook,
      deletable: deletable,
      readonly: readonly,
      rerunContext: rerunContext,
    );
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
          'Maintain the state board for the conversation above using the tools, then call finish.',
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

  static AgentTool _readVariables(
    MaintenanceStaging staging,
    Set<String> deletable,
    Set<String> readonly,
  ) => AgentTool(
    tool: const LlmTool(
      name: 'readVariables',
      description:
          'Read the working copy of the session variable board (including your staged changes) '
          'and the access tiers of existing keys. Local and free.',
      parameters: {'type': 'object', 'properties': {}},
    ),
    execute: (args) async => jsonEncode({
      'values': staging.workingCopy,
      'access': {
        'deletable': deletable.toList()..sort(),
        'readonly': readonly.toList()..sort(),
      },
    }),
  );

  static AgentTool _setVariables(MaintenanceStaging staging, {String? description}) => AgentTool(
    tool: LlmTool(
      name: 'setVariables',
      description: description ??
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
        throw const AgentToolFailure('variables must be an object of key → scalar value.');
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

  static AgentTool _removeVariables(MaintenanceStaging staging, {String? description}) => AgentTool(
    tool: LlmTool(
      name: 'removeVariables',
      description: description ??
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
        throw const AgentToolFailure('keys must be an array of exact key strings.');
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
          errors.add('removal limit reached ($maxRemovalsPerRun distinct keys per run)');
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
    Future<List<Message>> Function({int? beforeSeq, required int limit}) readHistory,
  ) => AgentTool(
    tool: const LlmTool(
      name: 'readHistory',
      description:
          'Page backwards through the session conversation (read-only, with seq numbers) to '
          'verify facts and their sources. Each page is at most 2000 chars. Pass beforeSeq to '
          'continue paging older; omit it for the newest page.',
      parameters: {
        'type': 'object',
        'properties': {
          'beforeSeq': {
            'type': 'integer',
            'description': 'Return messages with seq < beforeSeq. Omit for the newest page.',
          },
        },
      },
    ),
    execute: (args) async {
      final raw = args['beforeSeq'];
      if (raw != null && raw is! int) {
        throw const AgentToolFailure('beforeSeq must be an integer.');
      }
      final rows = await readHistory(
        beforeSeq: raw as int?,
        limit: readHistoryPageLimit,
      );
      if (rows.isEmpty) {
        return 'No chat messages before this point.';
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

  static AgentTool _setImagePrompts(MaintenanceStaging staging, int imageCount) =>
      AgentTool(
        tool: LlmTool(
          name: 'setImagePrompts',
          description:
              'Stage the scene descriptions for this round\'s image generation: exactly '
              '$imageCount English NovelAI tag string(s) per the image_guide, each a distinct '
              'framing of the SAME current scene. Replaces any previously staged prompts.',
          parameters: {
            'type': 'object',
            'properties': {
              'prompts': {
                'type': 'array',
                'items': {'type': 'string'},
                'minItems': 1,
                'maxItems': imageCount,
              },
            },
            'required': ['prompts'],
          },
        ),
        execute: (args) async {
          final raw = args['prompts'];
          if (raw is! List ||
              raw.isEmpty ||
              raw.length > imageCount ||
              raw.any((p) => p is! String || p.trim().isEmpty)) {
            throw AgentToolFailure(
              'prompts must be 1..$imageCount non-empty tag strings.',
            );
          }
          staging.imagePrompts = [for (final p in raw.cast<String>()) p.trim()];
          return 'Staged ${staging.imagePrompts!.length} image prompt(s). They generate on finish.';
        },
      );

  // ---- 提示词:数据段与 legacy 逐字同构(共享 builder),契约改工具措辞。

  static ({String stable, String variable, String combined}) _buildPrompt({
    required Map<String, String> variables,
    required List<Message> history,
    required List<Message> variableHistory,
    required BackgroundFeatures features,
    required int imageCount,
    String? imageGuide,
    String? memory,
    CharacterCard? character,
    List<WorldbookEntry> worldbook = const [],
    Set<String> deletable = const {},
    Set<String> readonly = const {},
    RerunContext? rerunContext,
  }) {
    final stageTools = [
      if (features.variables) 'setVariables / removeVariables',
      if (features.image) 'setImagePrompts',
    ].join(' / ');
    final verifyTools =
        features.variables ? 'readVariables / readHistory' : 'readHistory';
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
        '- Act only via tool calls: stage changes with $stageTools, verify with $verifyTools, '
        'and call finish to commit and end the run.',
      )
      ..writeln(
        '- Changes are staged in memory and applied atomically on finish; a failed or cancelled '
        'run discards everything. Do not restate unchanged state.',
      )
      ..writeln()
      ..writeln('# How to read the context sections')
      ..writeln(
        '- The recent_conversation section is the ONLY source of truth for the current image scene; '
        'it is read-only context, not a source of variable updates.',
      )
      ..writeln(
        '- Any memory, character, worldbook_background or image_guide section that appears below '
        'is durable, read-only background: never contradict it, never copy it into your output, '
        'and never invent facts that fight it. These sections may be absent — work with what is '
        'present.',
      )
      ..writeln();
    if (features.variables) {
      instruction
        ..writeln('# variables')
        ..writeln(
          '- Variables are the session\'s durable state board: short key-value pairs for facts that '
          'persist and can change across the story (location, time, condition, goals, relationships, '
          'possessions, ongoing effects). They are not a per-scene summary.',
        )
        ..writeln(
          '- Update variables ONLY from the variable_delta section, the unprocessed turns for this run.',
        )
        ..writeln(
          '- Never replay old changes from the read-only recent_conversation section.',
        )
        ..writeln(
          '- Stage only the keys whose value CHANGED in variable_delta via setVariables.',
        )
        ..writeln(
          '- YOU MAY AND SHOULD CREATE NEW KEYS: when variable_delta establishes a durable fact of '
          'this kind that no existing key covers, add it with a short, stable key and reuse that '
          'exact key in later runs. Prefer updating an existing key over creating a near-duplicate '
          'or synonym, and do not track transient scene details that will not matter again.',
        )
        ..writeln(
          '- Preserve existing keys exactly, including whitespace; keys must not be empty or whitespace-only.',
        )
        ..writeln(
          '- Values must be scalars: strings, finite numbers or booleans; never null, objects or arrays.',
        )
        ..writeln(
          '- To delete a key, call removeVariables with its EXACT existing key. Remove only when '
          'variable_delta shows the fact it tracks has ended, been left behind, or been permanently '
          'superseded. Never remove a key merely because it is absent from variable_delta or because the '
          'context looks cluttered; prefer updating it to a neutral value when the key still describes state.',
        )
        ..writeln(
          '- Only existing keys listed under variable_access.deletable may be removed; readonly '
          'keys must never be updated or removed. All other existing keys may be updated but never '
          'removed. New keys may always be created.',
        )
        ..writeln(
          '- At most $maxRemovalsPerRun distinct removals per run. A key must never end up both '
          'updated and removed: the last action wins.',
        )
        ..writeln(
          '- readVariables shows the working copy including your staged changes; readHistory pages '
          'older conversation to verify facts and their sources.',
        )
        ..writeln();
    }
    if (features.image) {
      instruction
        ..writeln('# image')
        ..writeln(
          '- When this round generates images, stage exactly $imageCount scene description(s) via '
          'setImagePrompts — never a generic or stale image. Describe the CURRENT scene read from '
          'the recent_conversation section: who is present, where, the action, lighting and mood.',
        )
        ..writeln(
          '- Reproduce each character\'s established appearance EXACTLY as pinned by the '
          'image_guide (and the character / memory sections when present); never alter what those '
          'fix. Vary only scene-specific pose, expression, action and mood.',
        )
        ..writeln(
          '- Write each as the English NovelAI tag format defined in the image_guide: one '
          'comma-separated tag string, not a sentence.',
        );
      if (imageCount > 1) {
        instruction
          ..writeln()
          ..writeln(
            '- The user wants $imageCount images: stage exactly $imageCount DIFFERENT tag strings, '
            'each a distinct framing (shot size / angle / composition / focus / mood) of the SAME '
            'current scene, mutually consistent and each independently usable.',
          );
      }
      instruction.writeln();
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
          worldbookChars: BackgroundEngine.maxBackgroundWorldbookChars,
          worldbookEntryChars: BackgroundEngine.maxBackgroundWorldbookEntryChars,
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
  static String _rerunInstruction(RerunContext context, BackgroundFeatures features) {
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
        ..add(backgroundTruncate(direction, BackgroundEngine.maxRerunDirectionChars))
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
          backgroundTruncate(prompt, BackgroundEngine.maxRerunPreviousImageChars),
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
        '${staging.imagePrompts?.length ?? 0} image prompt(s). Call finish to commit.';
  }
}

/// 审计 profile(hybrid 周期):全量变量板 + 权限 + 宽历史窗取证,工具面去掉
/// setImagePrompts(审计不生图)。契约与维护刻意不同 —— 维护只从 variable_delta
/// 取变化,审计可据宽窗合并近义键/修剪陈旧事实/修正矛盾,保守优先。复用维护的
/// 暂存态与四个工具执行器(同库私有静态成员),提交仍走原 compareAndApply。
class AuditProfile {
  /// 触发间隔:每 N 个成功变量轮(变量真应用)跑一次审计。计数器 per-session
  /// 内存态,切会话/重启清零;成败重置,让位/取消不重置(稍后重试)。
  static const int auditInterval = 5;

  /// 审计宽历史窗条数(取证上下文,比维护的参考窗宽)。
  static const int maxAuditHistoryMessages = 30;

  static const String _kAuditSetDescription =
      'Stage variable board corrections, applied atomically on finish. Merge near-duplicate or '
      'synonym keys into one canonical key, fix values contradicted by the evidence, and '
      'consolidate stale state. Base every correction on the audit_history evidence and '
      'readHistory, never on guesswork. Values must be scalars (string, finite number, boolean). '
      'Readonly keys cannot be updated.';

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
    required Future<List<Message>> Function({int? beforeSeq, required int limit})
        readHistory,
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

    // 工具面:读/改/删/翻页四件,无 setImagePrompts(审计不生图)。
    final registry = AgentToolRegistry()
      ..register(MaintenanceProfile._readVariables(staging, deletable, readonly))
      ..register(
        MaintenanceProfile._setVariables(staging, description: _kAuditSetDescription),
      )
      ..register(
        MaintenanceProfile._removeVariables(staging, description: _kAuditRemoveDescription),
      )
      ..register(MaintenanceProfile._readHistory(readHistory));

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
        '- Act only via tool calls: stage corrections with setVariables / removeVariables, '
        'verify with readVariables / readHistory, and call finish to commit and end the run.',
      )
      ..writeln(
        '- Changes are staged in memory and applied atomically on finish; a failed or cancelled '
        'run discards everything. Do not restate unchanged state.',
      )
      ..writeln()
      ..writeln('# How to read the context sections')
      ..writeln(
        '- The audit_history section is a wide window of recent conversation turns: it is your '
        'EVIDENCE for auditing the board. Unlike per-turn maintenance, you MAY correct the board '
        'based on this wider evidence.',
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
      ..writeln()
      ..writeln('# Conservative first')
      ..writeln(
        '- When unsure, DO NOT touch a key. Never remove or rewrite a key merely because the '
        'board looks cluttered or because you cannot find its source; absence of evidence is not '
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
        'whitespace-only. Values must be scalars: strings, finite numbers or booleans; never '
        'null, objects or arrays.',
      )
      ..writeln(
        '- To delete a key, call removeVariables with its EXACT existing key. Only keys listed '
        'under variable_access.deletable may be removed; readonly keys must never be updated or '
        'removed. All other existing keys may be updated but never removed.',
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
        '- readVariables shows the working copy including your staged changes; readHistory pages '
        'older conversation to verify facts and their sources.',
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
  static String _auditSoftReminder(MaintenanceStaging staging, int step, int count) {
    final urgency = switch (count) {
      1 => 'Please wrap up soon.',
      2 => 'You should finish now.',
      _ => 'Finish immediately with the changes staged so far.',
    };
    return 'Step $step: $urgency Staged so far: ${staging.updates.length} update(s), '
        '${staging.removals.length} removal(s). Call finish to commit.';
  }
}