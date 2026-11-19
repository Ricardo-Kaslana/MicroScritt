// 后台维护:自动维护轮、记忆/生图指导主动轮、/rerun 重跑与后台运行时解析;
// 所有后台轮经 _backgroundInFlight 串行,忙时合并待处理对话。
part of 'chat_controller.dart';

/// 后台 agent:自动维护轮/记忆与生图指导主动轮/后台运行时解析/结果摘要与失败文案。
abstract class ChatControllerBackground extends ChatControllerSession {
  /// 单次唤醒内最多连跑的后台轮数;剩余待处理对话留到下一次输入。
  static const _maxMaintenanceRounds = 2;

  /// 自动维护入口:累加唤醒号并合并待处理标志;在飞轮不打断,新对话只标记
  /// 待处理,当前轮收敛后由 [_startPendingMaintenance] 续跑。生图与变量维护
  /// 同轮触发,变量维护从固定基线起步(最近三条)。
  void _fireBackgroundMaintenance(int targetSeq) {
    final sessionId = state.sessionId;
    if (sessionId == null) return;
    final allFeatures = ref.read(backgroundFeaturesProvider);
    _backgroundWake++;
    _backgroundTargetSeq = targetSeq;
    // 本周期首次触发时固定基线:只补最近三条的起点,不把重入前的古老历史
    // 当成未处理;基线在失败轮保持不变。
    if (allFeatures.variables && _backgroundCursorSeq == null) {
      _backgroundBaselineSeq ??= targetSeq;
    } else if (!allFeatures.variables) {
      _backgroundCursorSeq = null;
      _backgroundBaselineSeq = null;
    }
    if (!allFeatures.image) {
      _backgroundPendingImage = false;
    } else {
      _backgroundPendingImage = true;
      _backgroundImageWake = _backgroundWake;
    }
    if (!allFeatures.variables && !_backgroundPendingImage) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '后台未选中任何维护功能,本轮后台维护已跳过',
      );
      return;
    }
    _backgroundPending = true;
    if (_backgroundInFlight) {
      // 让位规则:审计在飞时新对话优先 —— 取消审计(丢弃暂存),其 finally
      // 见 pending 补跑 delta 维护;计数器不重置,稍后重试。非审计在飞轮
      // (维护/memory/rerun)沿用合并语义,不打断。
      if (_auditRunning) {
        _backgroundToken.cancel();
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.running,
          backgroundSummary: '新对话优先,变量板审计已让位',
        );
        return;
      }
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.running,
        backgroundSummary: '后台维护仍在运行,新对话已合并待处理',
      );
      return;
    }
    _startPendingMaintenance();
  }

  /// 启动待处理的后台维护轮(串行):同一时刻只允许一个在飞轮,令牌在入口
  /// 换发;会话已切换或后台被关闭时直接返回。
  void _startPendingMaintenance() {
    if (!ref.mounted || _backgroundInFlight || !_backgroundPending) return;
    final sessionId = state.sessionId;
    if (sessionId == null || !ref.read(backgroundEnabledProvider)) return;
    _backgroundInFlight = true;
    _backgroundToken = InterruptToken();
    backgroundTask = _runBackgroundMaintenance(
      sessionId: sessionId,
      epoch: _backgroundEpoch,
      token: _backgroundToken,
    );
    unawaited(backgroundTask!);
  }

  /// 解析后台用运行时(后端/模型/参数):后台 agent 若指定了专用模型,则用该
  /// 模型(可解耦于主写引擎的模型);未指定(或该模型已失效)时回退主写引擎的
  /// 后端与模型。推理强度取后台独立设置(background_reasoning_level),不跟随
  /// 主对话的推理等级。后端未配置返回 null。
  Future<
    ({
      LlmBackend backend,
      BackendConfig config,
      String model,
      double temperature,
      int? maxTokens,
      ReasoningLevel reasoningLevel,
    })?
  >
  _resolveBackgroundRuntime() async {
    final config = ref.read(backendConfigProvider);
    final mainBackend = ref.read(backendProvider);
    if (config == null || mainBackend == null) return null;
    var backend = mainBackend;
    var selectedConfig = config;
    var model = config.model;
    var temperature = config.temperature;
    var maxTokens = config.maxTokens;
    final reasoningLevel = ref
        .read(appSettingsProvider)
        .backgroundReasoningLevel;
    final bgModelId = ref.read(appSettingsProvider).backgroundModelId;
    if (bgModelId != null) {
      final bgConfig = await ref
          .read(llmProviderRepositoryProvider)
          .loadConfigForModel(bgModelId);
      if (bgConfig != null && ref.mounted) {
        backend = createBackend(bgConfig);
        selectedConfig = bgConfig;
        model = bgConfig.model;
        temperature = bgConfig.temperature;
        maxTokens = bgConfig.maxTokens;
      }
    }
    if (!ref.mounted) return null;
    return (
      backend: backend,
      config: selectedConfig,
      model: model,
      temperature: temperature,
      maxTokens: maxTokens,
      reasoningLevel: reasoningLevel,
    );
  }

  /// 主动初始化会话记忆:新会话记忆为空时,用户点击「生成初始记忆」触发一次,依据
  /// **角色卡 + 常驻(恒定)世界书**生成一份初始长期记忆并落库。记忆由用户主动
  /// 维护:初始化/手动编辑/全量重生成([regenerateMemory])三途,后台 agent 不再
  /// 逐轮改写(记忆非空时按钮本就不出现,这里再防御一次)。
  ///
  /// 与自动后台维护共用 [_backgroundInFlight] 串行化与后台专用模型选择,避免两轮
  /// 后台 LLM 并发写记忆互相覆盖。
  Future<void> initializeMemory() async {
    final sessionId = state.sessionId;
    final character = state.character;
    if (sessionId == null || character == null) return;
    if (ref.read(backendConfigProvider) == null ||
        ref.read(backendProvider) == null) {
      return;
    }
    if (_busy || _backgroundInFlight) {
      // 主写/后台轮正在运行:串行化跳过,但不静默 —— 给一条可见的跳过原因,
      // 避免用户点了按钮却毫无反馈。
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '主写或后台维护正在运行,记忆初始化已跳过',
      );
      return;
    }
    final epoch = _backgroundEpoch;
    final current = await ref
        .read(memoryRepositoryProvider)
        .bySession(sessionId);
    if (!ref.mounted ||
        epoch != _backgroundEpoch ||
        _busy ||
        _backgroundInFlight) {
      return;
    }
    if (current.any((m) => m.content.trim().isNotEmpty)) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '记忆已存在,无需初始化',
      );
      return;
    }
    _backgroundInFlight = true;
    // 本轮令牌:此刻无任何在飞后台轮(串行化已保证),换新实例并捕获;
    // 闭包与结果判定都认这个实例。
    _backgroundToken = InterruptToken();
    final token = _backgroundToken;
    state = state.copyWith(
      backgroundStatus: BackgroundStatus.running,
      backgroundSummary: '正在初始化记忆…',
    );
    backgroundTask = _runMemoryAction(
      sessionId: sessionId,
      runningSummary: '正在初始化记忆…',
      token: token,
      action: (orchestrator, runtime) => orchestrator.initializeMemory(
        sessionId: sessionId,
        model: runtime.model,
        character: character,
        worldbook: state.worldbook,
        temperature: runtime.temperature,
        maxTokens: runtime.maxTokens,
        reasoningLevel: runtime.reasoningLevel,
        shouldCancel: () => token.cancelled,
        cancelSignal: token.whenCancelled,
      ),
    );
    unawaited(backgroundTask!);
  }

  /// 全量重生成记忆(用户主动发起,具有所有上下文的请求):把会话全部活跃
  /// 对话连同角色卡、常驻世界书与既有记忆送入 LLM,产出新记忆整段替换落库。
  /// 落库后**不**立即改冻结副本 —— 下一次输入以 diff 通知送达差异,压缩或
  /// 「应用到上下文」时才整体换新(保证第 0 条消息的缓存稳定)。
  Future<void> regenerateMemory() async {
    final sessionId = state.sessionId;
    final character = state.character;
    if (sessionId == null || character == null) return;
    if (ref.read(backendConfigProvider) == null ||
        ref.read(backendProvider) == null) {
      return;
    }
    if (_busy || _backgroundInFlight) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '主写或后台维护正在运行,记忆重生成已跳过',
      );
      return;
    }
    _backgroundInFlight = true;
    // 本轮令牌:此刻无任何在飞后台轮(串行化已保证),换新实例并捕获;
    // 闭包与结果判定都认这个实例。
    _backgroundToken = InterruptToken();
    final token = _backgroundToken;
    state = state.copyWith(
      backgroundStatus: BackgroundStatus.running,
      backgroundSummary: '正在依据全部对话重生成记忆…',
    );
    backgroundTask = _runMemoryAction(
      sessionId: sessionId,
      runningSummary: '正在依据全部对话重生成记忆…',
      token: token,
      action: (orchestrator, runtime) async => orchestrator.regenerateMemory(
        sessionId: sessionId,
        model: runtime.model,
        character: character,
        worldbook: state.worldbook,
        temperature: runtime.temperature,
        maxTokens: runtime.maxTokens,
        reasoningLevel: runtime.reasoningLevel,
        shouldCancel: () => token.cancelled,
        cancelSignal: token.whenCancelled,
        stripSkillNames: await enabledSkillNames(),
      ),
    );
    unawaited(backgroundTask!);
  }

  /// 主动初始化会话生图指导:空指导时,用户点击「生成初始指导」触发一次,依据
  /// **角色卡 + 常驻世界书**产出定妆外貌/风格基调的英文 tag 指导并落库;此后
  /// 后台 agent 每轮携带最新指导文本做生图维护(无冻结语义,编辑即生效)。
  Future<void> initializeImageGuide() async {
    final sessionId = state.sessionId;
    final character = state.character;
    if (sessionId == null || character == null) return;
    if (ref.read(backendConfigProvider) == null ||
        ref.read(backendProvider) == null) {
      return;
    }
    if (_busy || _backgroundInFlight) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '主写或后台维护正在运行,生图指导初始化已跳过',
      );
      return;
    }
    final epoch = _backgroundEpoch;
    final current = await ref
        .read(imageGuideRepositoryProvider)
        .bySession(sessionId);
    if (!ref.mounted ||
        epoch != _backgroundEpoch ||
        _busy ||
        _backgroundInFlight) {
      return;
    }
    if (current.any((g) => g.content.trim().isNotEmpty)) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.skipped,
        backgroundSummary: '生图指导已存在,可直接编辑',
      );
      return;
    }
    _backgroundInFlight = true;
    // 本轮令牌:此刻无任何在飞后台轮(串行化已保证),换新实例并捕获;
    // 闭包与结果判定都认这个实例。
    _backgroundToken = InterruptToken();
    final token = _backgroundToken;
    state = state.copyWith(
      backgroundStatus: BackgroundStatus.running,
      backgroundSummary: '正在初始化生图指导…',
    );
    backgroundTask = _runMemoryAction(
      sessionId: sessionId,
      runningSummary: '正在初始化生图指导…',
      token: token,
      isImageGuide: true,
      action: (orchestrator, runtime) => orchestrator.initializeImageGuide(
        sessionId: sessionId,
        model: runtime.model,
        character: character,
        worldbook: state.worldbook,
        temperature: runtime.temperature,
        maxTokens: runtime.maxTokens,
        reasoningLevel: runtime.reasoningLevel,
        shouldCancel: () => token.cancelled,
        cancelSignal: token.whenCancelled,
      ),
    );
    unawaited(backgroundTask!);
  }

  /// 记忆/生图指导主动轮的公共执行体(独立 future,与自动后台维护同构地解耦)。
  /// [action] 在解析出运行时后执行;[isImageGuide] 区分落库后的失效对象
  /// (记忆失效 memoriesProvider + 重算上下文;指导失效 imageGuideProvider)。
  /// [runningSummary] 仅用于异常兜底文案。[token] 是调用方捕获的本轮中断
  /// 令牌:结果判定只认它,不读控制器字段 —— 期间并发的其它轮换发不影响本轮
  /// 的"已中断"判定。
  Future<void> _runMemoryAction({
    required int sessionId,
    required String runningSummary,
    required InterruptToken token,
    required Future<BackgroundTurnResult> Function(
      Orchestrator orchestrator,
      ({
        LlmBackend backend,
        BackendConfig config,
        String model,
        double temperature,
        int? maxTokens,
        ReasoningLevel reasoningLevel,
      })
      runtime,
    )
    action,
    bool isImageGuide = false,
  }) async {
    final epoch = _backgroundEpoch;
    final wake = _backgroundWake;
    final actionLabel = isImageGuide
        ? '生图指导初始化'
        : (runningSummary.contains('重生成') ? '记忆重生成' : '记忆初始化');
    try {
      final runtime = await _resolveBackgroundRuntime();
      if (runtime == null ||
          token.cancelled ||
          !_ownsBackground(sessionId, epoch, token)) {
        return;
      }

      final turn = await action(
        Orchestrator(
          BackgroundEngine(runtime.backend),
          ref.read(variableRepositoryProvider),
          ref.read(memoryRepositoryProvider),
          ref.read(messageRepositoryProvider),
          ref.read(imageGuideRepositoryProvider),
        ),
        runtime,
      );

      if (!_ownsBackground(sessionId, epoch, token)) return;

      final bgResult = turn.result;
      final produced = isImageGuide
          ? bgResult?.imageGuide != null
          : bgResult?.memoryUpdate != null;
      // 主动轮同样计入逐请求统计:成功轮带真实用量;失败/中断轮只计请求次数。
      if (bgResult != null) {
        unawaited(
          _recordUsage(
            sessionId: sessionId,
            kind: UsageKind.background,
            config: runtime.config,
            usage: bgResult.usage,
            reported:
                bgResult.usage.inputTokens > 0 ||
                bgResult.usage.outputTokens > 0 ||
                bgResult.usage.cachedInputTokens > 0,
          ),
        );
      } else if (!turn.skipped && !token.cancelled) {
        unawaited(
          _recordUsage(
            sessionId: sessionId,
            kind: UsageKind.background,
            config: runtime.config,
            usage: const TokenUsage(),
            reported: false,
          ),
        );
      }
      if (bgResult != null && produced) {
        state = state.copyWith(
          backgroundInputTokens: bgResult.usage.inputTokens,
          backgroundOutputTokens: bgResult.usage.outputTokens,
          backgroundCachedInputTokens: bgResult.usage.cachedInputTokens,
          backgroundStatus: BackgroundStatus.succeeded,
          backgroundSummary: isImageGuide
              ? '生图指导已初始化,后台生图将遵循该指导'
              : (actionLabel == '记忆重生成' ? '记忆已重生成,下次输入将以差异通知送达' : '记忆已初始化'),
        );
        if (ref.mounted) {
          if (isImageGuide) {
            // 指导落库即生效(后台每轮直接读库,无冻结语义)。
            ref.invalidate(imageGuideProvider(sessionId));
          } else {
            // 记忆落了库:失效 memoriesProvider,状态面板立即读新值。
            ref.invalidate(memoriesProvider(sessionId));
            // 首次建立记忆(上下文尚无冻结副本):直接采纳为"第 0 条消息"的
            // 冻结副本并重算快照 —— 第 0 条从无到有本就是一次性的前缀变化,
            // 无缓存可保护;与 _memoryDiffNotice 的首次采纳语义一致。
            if ((_frozenMemory ?? '').trim().isEmpty) {
              final rows = await ref
                  .read(memoryRepositoryProvider)
                  .bySession(sessionId);
              if (ref.mounted &&
                  state.sessionId == sessionId &&
                  rows.isNotEmpty) {
                _frozenMemory = rows.first.content;
                _memoryDiffNotifiedHash = null;
                state = state.copyWith(frozenMemory: _frozenMemory);
              }
              await _reassembleContext();
            }
          }
        }
      } else if (token.cancelled) {
        // 主动轮被用户中断:本轮运行丢弃,不落库。
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '$actionLabel已中断',
        );
      } else if (turn.skipped) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.skipped,
          backgroundSummary: turn.skippedReason.isEmpty
              ? '$actionLabel未产出内容'
              : turn.skippedReason,
        );
      } else {
        // 引擎失败:按细分原因给出更具体的文案;引擎披露的诊断摘要
        // (后端错误消息 / 响应片段)拼在括号里,帮用户区分网关报错与空响应。
        final reason = turn.failureReason;
        final base = switch (reason) {
          BackgroundFailureReason.backendError => '$actionLabel调用出错,请重试',
          BackgroundFailureReason.parseFailure => '$actionLabel返回解析失败,请重试',
          BackgroundFailureReason.cancelled => '$actionLabel已中断',
          null => '$actionLabel未产出可用结果',
        };
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: _withFailureDetail(base, turn.failureDetail),
        );
      }
    } catch (_) {
      if (!_ownsBackground(sessionId, epoch, token)) return;
      if (token.cancelled) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '$actionLabel已中断',
        );
      } else {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: '$actionLabel异常,已安全跳过',
        );
      }
    } finally {
      if (_ownsBackground(sessionId, epoch, token)) {
        if (token.cancelled &&
            state.backgroundStatus == BackgroundStatus.running) {
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.interrupted,
            backgroundSummary: '$actionLabel已中断',
          );
        }
        _backgroundInFlight = false;
        await _persistTokenUsage();
        if (!token.cancelled &&
            wake != _backgroundWake &&
            _ownsBackground(sessionId, epoch, token)) {
          _startPendingMaintenance();
        }
      }
    }
  }

  /// 自动维护轮执行体:至多 [_maxMaintenanceRounds] 轮,每轮核对令牌/代数/
  /// 唤醒号,只消费属于自己的待处理标志;变量有剩余或期间来了新对话时续跑,
  /// 图片任务与轮次解耦,由落点回调记录替换目标。
  Future<void> _runBackgroundMaintenance({
    required int sessionId,
    required int epoch,
    required InterruptToken token,
  }) async {
    bool cancelled() =>
        token.cancelled || !_ownsBackground(sessionId, epoch, token);
    var inputTokens = 0, outputTokens = 0, cachedTokens = 0;
    try {
      final baseline = _backgroundBaselineSeq;
      if (_backgroundCursorSeq == null && baseline != null) {
        final all = await ref
            .read(messageRepositoryProvider)
            .bySession(sessionId);
        if (cancelled()) return;
        final rows = all
            .where(
              (m) =>
                  m.isChat &&
                  m.role != 'system' &&
                  m.content.isNotEmpty &&
                  m.seq <= baseline,
            )
            .toList();
        final start = rows.length > 3 ? rows.length - 3 : 0;
        _backgroundCursorSeq = rows.isEmpty ? -1 : rows[start].seq - 1;
      }
      final runtime = await _resolveBackgroundRuntime();
      if (runtime == null || cancelled()) return;
      for (var round = 0; round < _maxMaintenanceRounds; round++) {
        if (cancelled() || !ref.read(backgroundEnabledProvider)) break;
        final wake = _backgroundWake;
        final imageWake = _backgroundImageWake;
        final targetSeq = _backgroundTargetSeq;
        final selected = ref.read(backgroundFeaturesProvider);
        final features = BackgroundFeatures(
          variables: selected.variables,
          image: selected.image && _backgroundPendingImage,
        );
        _backgroundPending = false;
        if (!features.anyEnabled || targetSeq == null) break;
        state = state.copyWith(backgroundStatus: BackgroundStatus.running);
        final stripNames = await enabledSkillNames();
        if (cancelled()) return;
        // 调用时读(与 confirmVariableDeletions 同模式):轮间切换模式即时生效。
        final mode = ref.read(appSettingsProvider).backgroundMode;
        // 本轮的图片落点收集器:生图任务与轮次解耦,回调可能早于 runAfterTurn
        // 返回,所以先挂上收集器再发起调用。
        final roundImages = <BackgroundImagePlacement>[];
        _activeImageRecord = roundImages;
        final turn =
            await Orchestrator(
              BackgroundEngine(runtime.backend),
              ref.read(variableRepositoryProvider),
              ref.read(memoryRepositoryProvider),
              ref.read(messageRepositoryProvider),
              ref.read(imageGuideRepositoryProvider),
              imageBackend: ref.read(imageBackendProvider),
              onImagePlaced: _imagePlacementHandler(
                sessionId: sessionId,
                epoch: epoch,
                roundImages: roundImages,
                replacedText: '图片已重绘',
                appendedText: '图片已生成',
                // 期间又来了新对话(唤醒号变了)时不改摘要:那轮的文案归它自己。
                summaryGuard: () => _backgroundImageWake == imageWake,
              ),
              onImageFailed: (detail) {
                if (!ref.mounted ||
                    state.sessionId != sessionId ||
                    _backgroundEpoch != epoch ||
                    _backgroundImageWake != imageWake) {
                  return;
                }
                state = state.copyWith(
                  backgroundSummary: state.backgroundSummary.replaceFirst(
                    '图片生成中',
                    _withFailureDetail('图片生成失败,已跳过', detail),
                  ),
                );
              },
            ).runAfterTurn(
              sessionId: sessionId,
              model: runtime.model,
              temperature: runtime.temperature,
              maxTokens: runtime.maxTokens,
              reasoningLevel: runtime.reasoningLevel,
              features: features,
              confirmVariableDeletions: ref
                  .read(appSettingsProvider)
                  .backgroundDeletionConfirm,
              shouldCancel: cancelled,
              cancelSignal: token.whenCancelled,
              afterSeq: features.variables ? _backgroundCursorSeq : null,
              throughSeq: targetSeq,
              character: state.character,
              worldbook: state.worldbook,
              characterAnchor: ref
                  .read(appSettingsProvider)
                  .backgroundCharacterAnchor,
              memoryAnchor: ref
                  .read(appSettingsProvider)
                  .backgroundMemoryAnchor,
              imageCount: (ref.read(imageConfigProvider)?.count ?? 1).clamp(
                1,
                6,
              ),
              stripSkillNames: stripNames,
              mode: mode,
              onAgentStep: (e) {
                if (!_ownsBackground(sessionId, epoch, token)) return;
                unawaited(
                  _recordUsage(
                    sessionId: sessionId,
                    kind: UsageKind.background,
                    config: runtime.config,
                    usage: e.usage,
                    reported: e.reported,
                  ),
                );
                // 每逻辑步一次网络往返,天然低频:逐事件直更,不加节流
                // 定时器;仅 running 态更新,不覆盖落定/失败摘要。
                if (state.backgroundStatus == BackgroundStatus.running) {
                  final tools = e.toolNames.isEmpty
                      ? ''
                      : ' · ${e.toolNames.join('+')}';
                  state = state.copyWith(
                    backgroundSummary: '维护中 · 步 ${e.step}$tools',
                  );
                }
              },
            );
        final result = turn.result;
        if (result != null && ref.mounted && turn.cursorSeq != null) {
          _invalidateVariableViews(sessionId, result);
        }
        if (!_ownsBackground(sessionId, epoch, token)) return;
        if (result != null) {
          // 轮级行仅 legacy:agentic 已由 onAgentStep 逐步入账,不另写轮级行。
          if (mode != BackgroundMode.agentic) {
            unawaited(
              _recordUsage(
                sessionId: sessionId,
                kind: UsageKind.background,
                config: runtime.config,
                usage: result.usage,
                reported:
                    result.usage.inputTokens > 0 ||
                    result.usage.outputTokens > 0 ||
                    result.usage.cachedInputTokens > 0,
              ),
            );
          }
          inputTokens += result.usage.inputTokens;
          outputTokens += result.usage.outputTokens;
          cachedTokens += result.usage.cachedInputTokens;
          if (turn.cursorSeq != null) _backgroundCursorSeq = turn.cursorSeq;
          // hybrid 周期审计计数:仅变量真应用的成功旧维护轮 +1(rerun 不计数,
          // 触发点在维护 finally)。agentic/legacy 不计数。
          if (mode == BackgroundMode.hybrid && turn.cursorSeq != null) {
            _auditCounter++;
          }
          if (turn.imageHandled && imageWake == _backgroundImageWake) {
            _backgroundPendingImage = false;
          }
          _backgroundPending = _backgroundPending || turn.hasMoreVariables;
          _recordMaintenanceWindow(turn, roundImages);
          state = state.copyWith(
            backgroundInputTokens: inputTokens,
            backgroundOutputTokens: outputTokens,
            backgroundCachedInputTokens: cachedTokens,
            backgroundStatus: BackgroundStatus.succeeded,
            backgroundSummary: _settledSummary(
              _backgroundSummary(result),
              roundImages,
              replacedText: '图片已生成',
            ),
            backgroundVariableStats: _variableStats(result),
          );
        } else if (token.cancelled) {
          _backgroundPending = false;
          _releaseImageRecord(roundImages);
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.interrupted,
            backgroundSummary: '后台维护已中断',
          );
          break;
        } else if (turn.skipped) {
          _backgroundPending = turn.variableConflict || _backgroundPending;
          _releaseImageRecord(roundImages);
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.skipped,
            backgroundSummary: turn.skippedReason,
          );
          break;
        } else {
          _backgroundPending = true;
          _releaseImageRecord(roundImages);
          // 后端报错/解析失败都已真实发起请求:计请求次数,无可用用量。
          // agentic 的失败/取消步已由 onAgentStep 计次,不另写零行。
          if (mode != BackgroundMode.agentic) {
            unawaited(
              _recordUsage(
                sessionId: sessionId,
                kind: UsageKind.background,
                config: runtime.config,
                usage: const TokenUsage(),
                reported: false,
              ),
            );
          }
          final base = switch (turn.failureReason) {
            BackgroundFailureReason.backendError => '后台调用出错,状态维护已跳过',
            BackgroundFailureReason.parseFailure => '后台返回解析失败,状态维护已跳过',
            BackgroundFailureReason.cancelled => '后台维护已中断',
            null => '后台维护未产出可用结果',
          };
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.failed,
            backgroundSummary: _withFailureDetail(base, turn.failureDetail),
          );
          if (wake == _backgroundWake) break;
        }
        if (!_backgroundPending || token.cancelled) break;
        if (round + 1 == _maxMaintenanceRounds) {
          state = state.copyWith(
            backgroundSummary: '${state.backgroundSummary} · 仍有对话待后续维护',
          );
        }
      }
    } catch (_) {
      if (!_ownsBackground(sessionId, epoch, token)) return;
      _backgroundPending = !token.cancelled;
      state = state.copyWith(
        backgroundStatus: token.cancelled
            ? BackgroundStatus.interrupted
            : BackgroundStatus.failed,
        backgroundSummary: token.cancelled ? '后台维护已中断' : '后台维护异常,已安全跳过',
      );
    } finally {
      if (_ownsBackground(sessionId, epoch, token)) {
        if (token.cancelled &&
            state.backgroundStatus == BackgroundStatus.running) {
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.interrupted,
            backgroundSummary: '后台维护已中断',
          );
        }
        _backgroundInFlight = false;
        await _persistTokenUsage();
        // 周期审计触发(单一触发源):persist 是交错窗口,fire 可能已换发令牌
        // 启动新维护 → 必须重新校验 ownership(B2)。delta 优先:有积压(pending)
        // 时不审计,留待排空后的成功轮再触发。
        if (_ownsBackground(sessionId, epoch, token) &&
            !token.cancelled &&
            !_backgroundPending &&
            _auditCounter >= AuditProfile.auditInterval &&
            ref.read(appSettingsProvider).backgroundMode ==
                BackgroundMode.hybrid &&
            ref.read(backgroundFeaturesProvider).variables) {
          _startBackgroundAudit();
        }
      }
    }
  }

  /// 启动一次变量板审计(串行,与自动维护/memory/rerun 共用 [_backgroundInFlight]
  /// 单槽,令牌入口换发 —— 「独立令牌」即自己的实例,非第二并发槽)。仅由维护
  /// finally 的周期触发点调用;忙/后台关闭/无会话时直接返回。throughSeq 在入口
  /// 同步捕获,隔离审计窗与并发新消息(防被 delta 双重处理)。
  void _startBackgroundAudit() {
    if (!ref.mounted || _backgroundInFlight) return;
    final sessionId = state.sessionId;
    if (sessionId == null || !ref.read(backgroundEnabledProvider)) return;
    _backgroundInFlight = true;
    _auditRunning = true;
    _backgroundToken = InterruptToken();
    final token = _backgroundToken;
    final throughSeq = _backgroundCursorSeq ?? _backgroundTargetSeq;
    state = state.copyWith(
      backgroundStatus: BackgroundStatus.running,
      backgroundSummary: '变量板审计中…',
    );
    backgroundTask = _runBackgroundAudit(
      sessionId: sessionId,
      epoch: _backgroundEpoch,
      token: token,
      throughSeq: throughSeq,
    );
    unawaited(backgroundTask!);
  }

  /// 审计执行体:镜像 [_runMemoryAction] 骨架,但 best-effort —— 成败/冲突/良性
  /// 跳过都重置计数器,取消(让位/interrupt)不重置;**不推进游标、不碰 rerun
  /// 窗口与图片簿记、不生图**。逐步用量经 onAgentStep 入账(agentic 约定,无轮级
  /// 行/无失败零行),成功轮 totalUsage 累加进后台桶。让位交接:finally 见
  /// [_backgroundPending] 补跑 delta 维护(不用 wake/!token.cancelled 条件 ——
  /// 让位会 cancel 令牌但置 pending)。
  Future<void> _runBackgroundAudit({
    required int sessionId,
    required int epoch,
    required InterruptToken token,
    required int? throughSeq,
  }) async {
    bool cancelled() =>
        token.cancelled || !_ownsBackground(sessionId, epoch, token);
    try {
      final runtime = await _resolveBackgroundRuntime();
      if (!_ownsBackground(sessionId, epoch, token)) return;
      if (runtime == null) {
        // 照 rerun:不静默 return 悬挂 running 态(停止键幽灵)。
        _auditCounter = 0;
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: '后台运行时不可用,审计已跳过',
        );
        return;
      }
      final stripNames = await enabledSkillNames();
      if (cancelled()) return;
      final turn =
          await Orchestrator(
            BackgroundEngine(runtime.backend),
            ref.read(variableRepositoryProvider),
            ref.read(memoryRepositoryProvider),
            ref.read(messageRepositoryProvider),
            ref.read(imageGuideRepositoryProvider),
          ).runAudit(
            sessionId: sessionId,
            model: runtime.model,
            temperature: runtime.temperature,
            maxTokens: runtime.maxTokens,
            reasoningLevel: runtime.reasoningLevel,
            throughSeq: throughSeq,
            confirmVariableDeletions: ref
                .read(appSettingsProvider)
                .backgroundDeletionConfirm,
            shouldCancel: cancelled,
            cancelSignal: token.whenCancelled,
            stripSkillNames: stripNames,
            onAgentStep: (e) {
              if (!_ownsBackground(sessionId, epoch, token)) return;
              unawaited(
                _recordUsage(
                  sessionId: sessionId,
                  kind: UsageKind.background,
                  config: runtime.config,
                  usage: e.usage,
                  reported: e.reported,
                ),
              );
              // 仅 running 且未取消时更新步文案:让位后晚到的步事件不得把
              // 「已让位」覆盖回「审计中」(用量照记,那是真实消耗)。
              if (state.backgroundStatus == BackgroundStatus.running &&
                  !token.cancelled) {
                final tools = e.toolNames.isEmpty
                    ? ''
                    : ' · ${e.toolNames.join('+')}';
                state = state.copyWith(
                  backgroundSummary: '审计中 · 步 ${e.step}$tools',
                );
              }
            },
          );
      if (!_ownsBackground(sessionId, epoch, token)) return;
      final result = turn.result;
      // 分支顺序(B3):success → cancelled → conflict → 普通 skipped → failed。
      // cancelled 必须先于 failed:failed(cancelled) 不得误重置计数器。
      if (result != null) {
        _auditCounter = 0;
        _invalidateVariableViews(sessionId, result);
        state = state.copyWith(
          backgroundInputTokens:
              state.backgroundInputTokens + result.usage.inputTokens,
          backgroundOutputTokens:
              state.backgroundOutputTokens + result.usage.outputTokens,
          backgroundCachedInputTokens:
              state.backgroundCachedInputTokens +
              result.usage.cachedInputTokens,
          backgroundStatus: BackgroundStatus.succeeded,
          backgroundSummary: _auditSummary(result),
        );
      } else if (token.cancelled) {
        // 让位/interrupt:周期未消费,计数器不重置,稍后重试。
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '审计已中断',
        );
      } else if (turn.skipped && turn.variableConflict) {
        _auditCounter = 0;
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.skipped,
          backgroundSummary: '审计跳过(变量板已被修改)',
        );
      } else if (turn.skipped) {
        // 良性跳过(空板/无对话):重置,防计数器恒 ≥5 此后每轮空触发。
        _auditCounter = 0;
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.skipped,
          backgroundSummary: turn.skippedReason,
        );
      } else {
        _auditCounter = 0;
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: _withFailureDetail(
            '审计失败,已跳过',
            turn.failureDetail,
          ),
        );
      }
    } catch (_) {
      if (!_ownsBackground(sessionId, epoch, token)) return;
      if (token.cancelled) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '审计已中断',
        );
      } else {
        _auditCounter = 0;
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: '审计异常,已安全跳过',
        );
      }
    } finally {
      // B4:无条件首句清标志 —— 放进 owns 块会在 ownership 失效路径(会话切换)
      // 永久遗留 true,破坏「_auditRunning ⟹ 审计持有当前令牌」不变量。
      _auditRunning = false;
      if (_ownsBackground(sessionId, epoch, token)) {
        if (token.cancelled &&
            state.backgroundStatus == BackgroundStatus.running) {
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.interrupted,
            backgroundSummary: '审计已中断',
          );
        }
        _backgroundInFlight = false;
        await _persistTokenUsage();
        // 让位交接:审计期间来了新对话(pending=true,含让位 cancel 的情形)
        // → 补跑 delta 维护。delta 永远优先。
        if (_backgroundPending) {
          _startPendingMaintenance();
        }
      }
    }
  }

  /// `/rerun [修改方向]`:把上一次成功的后台维护重做一遍 —— 变量按**同一批
  /// 对话**重放,生图**原地替换**那一轮落库的图片(目标已被删/清图/改描述时
  /// 回退追加)。后台提示词会显式标识这是重跑,并携带 [direction] 与上一轮
  /// 落库的图片描述供模型修订。
  /// 与自动维护互斥(共用 [_backgroundInFlight]),但完全不触碰普通进度:
  /// 游标、待处理标志、唤醒号都不动。
  ///
  /// 返回 null 表示已启动(状态转 running,由灵动岛/状态面板跟进);
  /// 非空是可展示的拒绝原因。
  String? rerunBackgroundMaintenance({String? direction}) {
    final sessionId = state.sessionId;
    if (sessionId == null) return '尚未加载会话,无法重跑';
    if (_backgroundInFlight) return '后台维护正在运行,请稍候再重跑';
    // 上一张图片还在生成/下载时同样拒绝:替换目标 id 可能还没记录完,
    // 且两个写入者会争同一行。
    if (_backgroundImageTask != null) return '上一张图片仍在生成,请稍候再重跑';
    if (ref.read(backendConfigProvider) == null ||
        ref.read(backendProvider) == null) {
      return '后端未配置,无法重跑';
    }
    final selected = ref.read(backgroundFeaturesProvider);
    final features = BackgroundFeatures(
      variables: selected.variables,
      image: selected.image && ref.read(imageBackendProvider) != null,
    );
    if (!features.anyEnabled) return '未选中可执行的维护功能,无法重跑';
    final window = _rerunWindow();
    if (window == null) return '当前轮尚无可重跑的对话';

    // 与记忆/指导主动轮同款换发语义:此刻没有在飞后台轮,换新令牌并捕获,
    // 结果判定只认这个实例。
    _backgroundInFlight = true;
    _backgroundToken = InterruptToken();
    final token = _backgroundToken;
    final replaceTargets = <ImageReplaceTarget>[
      for (final e in _lastMaintenanceImages)
        (messageId: e.messageId, expectedPrompt: e.prompt),
    ];
    final trimmedDirection = direction?.trim() ?? '';
    final rerunContext = RerunContext(
      direction: trimmedDirection.isEmpty ? null : trimmedDirection,
      // 上一轮图片描述只对生图重跑有意义;没有图/生图关闭时为空(提示词省略该段)。
      previousImagePrompts: features.image
          ? [
              for (final e in _lastMaintenanceImages)
                if (e.prompt.trim().isNotEmpty) e.prompt,
            ]
          : const [],
    );
    state = state.copyWith(
      backgroundStatus: BackgroundStatus.running,
      backgroundSummary: '正在重跑上次后台维护…',
    );
    backgroundTask = _runBackgroundRerun(
      sessionId: sessionId,
      epoch: _backgroundEpoch,
      token: token,
      features: features,
      afterSeq: window.afterSeq,
      throughSeq: window.throughSeq,
      replaceTargets: replaceTargets,
      rerunContext: rerunContext,
    );
    unawaited(backgroundTask!);
    return null;
  }

  /// 重跑窗口:优先上一次成功维护**实际处理的那批对话**;没有记录(重启/切会话/
  /// 那轮没跑变量)时回退到最新一轮「用户消息 + 助手回复」,连用户消息都没有时
  /// 交给编排器的无游标 bootstrap(最近三条)。
  ({int? afterSeq, int throughSeq})? _rerunWindow() {
    final recordedAfter = _lastMaintenanceAfterSeq;
    final recordedThrough = _lastMaintenanceThroughSeq;
    if (recordedAfter != null && recordedThrough != null) {
      return (afterSeq: recordedAfter, throughSeq: recordedThrough);
    }
    // 显示窗口恒含尾部,不必再读库。
    final rows = state.messages
        .where((m) => m.isChat && m.role != 'system' && m.content.isNotEmpty)
        .toList();
    int? replySeq;
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i].role == 'assistant') {
        replySeq = rows[i].seq;
        break;
      }
    }
    if (replySeq == null) return null;
    int? userSeq;
    for (final m in rows) {
      if (m.role == 'user' && m.seq < replySeq) userSeq = m.seq;
    }
    return (
      afterSeq: userSeq == null ? null : userSeq - 1,
      throughSeq: replySeq,
    );
  }

  /// 重跑执行体(单发,不走 [_maxMaintenanceRounds] 多轮循环):一次
  /// [Orchestrator.runAfterTurn],显式传重放窗口与图片替换目标。
  Future<void> _runBackgroundRerun({
    required int sessionId,
    required int epoch,
    required InterruptToken token,
    required BackgroundFeatures features,
    required int? afterSeq,
    required int throughSeq,
    required List<ImageReplaceTarget> replaceTargets,
    required RerunContext rerunContext,
  }) async {
    bool cancelled() =>
        token.cancelled || !_ownsBackground(sessionId, epoch, token);
    final wake = _backgroundWake;
    final roundImages = <BackgroundImagePlacement>[];

    try {
      final runtime = await _resolveBackgroundRuntime();
      if (!_ownsBackground(sessionId, epoch, token)) return;
      if (runtime == null) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: '后台运行时不可用,重跑已跳过',
        );
        return;
      }
      _activeImageRecord = roundImages;
      final stripNames = await enabledSkillNames();
      if (cancelled()) return;
      final mode = ref.read(appSettingsProvider).backgroundMode;
      final turn =
          await Orchestrator(
            BackgroundEngine(runtime.backend),
            ref.read(variableRepositoryProvider),
            ref.read(memoryRepositoryProvider),
            ref.read(messageRepositoryProvider),
            ref.read(imageGuideRepositoryProvider),
            imageBackend: ref.read(imageBackendProvider),
            onImagePlaced: _imagePlacementHandler(
              sessionId: sessionId,
              epoch: epoch,
              roundImages: roundImages,
              replacedText: '图片已重绘',
              appendedText: '图片已生成',
            ),
            onImageFailed: (detail) {
              if (!ref.mounted ||
                  state.sessionId != sessionId ||
                  _backgroundEpoch != epoch) {
                return;
              }
              state = state.copyWith(
                backgroundSummary: state.backgroundSummary.replaceFirst(
                  '图片生成中',
                  _withFailureDetail('图片重绘失败,已跳过', detail),
                ),
              );
            },
          ).runAfterTurn(
            sessionId: sessionId,
            model: runtime.model,
            temperature: runtime.temperature,
            maxTokens: runtime.maxTokens,
            reasoningLevel: runtime.reasoningLevel,
            features: features,
            confirmVariableDeletions: ref
                .read(appSettingsProvider)
                .backgroundDeletionConfirm,
            shouldCancel: cancelled,
            cancelSignal: token.whenCancelled,
            afterSeq: features.variables ? afterSeq : null,
            throughSeq: throughSeq,
            character: state.character,
            worldbook: state.worldbook,
            characterAnchor: ref
                .read(appSettingsProvider)
                .backgroundCharacterAnchor,
            memoryAnchor: ref.read(appSettingsProvider).backgroundMemoryAnchor,
            imageCount: (ref.read(imageConfigProvider)?.count ?? 1).clamp(1, 6),
            stripSkillNames: stripNames,
            imageReplaceTargets: features.image ? replaceTargets : const [],
            rerunContext: rerunContext,
            mode: mode,
            onAgentStep: (e) {
              if (!_ownsBackground(sessionId, epoch, token)) return;
              unawaited(
                _recordUsage(
                  sessionId: sessionId,
                  kind: UsageKind.background,
                  config: runtime.config,
                  usage: e.usage,
                  reported: e.reported,
                ),
              );
              if (state.backgroundStatus == BackgroundStatus.running) {
                final tools = e.toolNames.isEmpty
                    ? ''
                    : ' · ${e.toolNames.join('+')}';
                state = state.copyWith(
                  backgroundSummary: '重跑中 · 步 ${e.step}$tools',
                );
              }
            },
          );
      final result = turn.result;
      if (!_ownsBackground(sessionId, epoch, token)) return;
      if (result != null) {
        // 轮级行仅 legacy:agentic 重跑同样逐步入账。
        if (mode != BackgroundMode.agentic) {
          unawaited(
            _recordUsage(
              sessionId: sessionId,
              kind: UsageKind.background,
              config: runtime.config,
              usage: result.usage,
              reported:
                  result.usage.inputTokens > 0 ||
                  result.usage.outputTokens > 0 ||
                  result.usage.cachedInputTokens > 0,
            ),
          );
        }
        if (turn.processedAfterSeq != null) {
          _invalidateVariableViews(sessionId, result);
          _lastMaintenanceAfterSeq = turn.processedAfterSeq;
          _lastMaintenanceThroughSeq = turn.processedThroughSeq;
        }
        _recordMaintenanceImages(turn, roundImages);
        state = state.copyWith(
          // 重跑也是真实后台调用:用量累加进后台桶(不是覆盖,与自动维护一致)。
          backgroundInputTokens:
              state.backgroundInputTokens + result.usage.inputTokens,
          backgroundOutputTokens:
              state.backgroundOutputTokens + result.usage.outputTokens,
          backgroundCachedInputTokens:
              state.backgroundCachedInputTokens +
              result.usage.cachedInputTokens,
          backgroundStatus: BackgroundStatus.succeeded,
          backgroundSummary: _settledSummary(
            '重跑完成 · ${_backgroundSummary(result)}',
            roundImages,
            replacedText: '图片已重绘',
          ),
          backgroundVariableStats: _variableStats(result),
        );
      } else if (token.cancelled) {
        _releaseImageRecord(roundImages);
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '重跑已中断',
        );
      } else if (turn.skipped) {
        _releaseImageRecord(roundImages);
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.skipped,
          backgroundSummary: turn.skippedReason.isEmpty
              ? '重跑未产出内容'
              : turn.skippedReason,
        );
      } else {
        _releaseImageRecord(roundImages);
        // 重跑调用的失败轮同样已发起请求:计请求次数,无可用用量。
        // agentic 的失败/取消步已由 onAgentStep 计次,不另写零行。
        if (mode != BackgroundMode.agentic) {
          unawaited(
            _recordUsage(
              sessionId: sessionId,
              kind: UsageKind.background,
              config: runtime.config,
              usage: const TokenUsage(),
              reported: false,
            ),
          );
        }
        final base = switch (turn.failureReason) {
          BackgroundFailureReason.backendError => '重跑调用出错,请重试',
          BackgroundFailureReason.parseFailure => '重跑返回解析失败,请重试',
          BackgroundFailureReason.cancelled => '重跑已中断',
          null => '重跑未产出可用结果',
        };
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.failed,
          backgroundSummary: _withFailureDetail(base, turn.failureDetail),
        );
      }
    } catch (_) {
      if (!_ownsBackground(sessionId, epoch, token)) return;
      _releaseImageRecord(roundImages);
      state = state.copyWith(
        backgroundStatus: token.cancelled
            ? BackgroundStatus.interrupted
            : BackgroundStatus.failed,
        backgroundSummary: token.cancelled ? '重跑已中断' : '重跑异常,已安全跳过',
      );
    } finally {
      if (_ownsBackground(sessionId, epoch, token)) {
        if (token.cancelled &&
            state.backgroundStatus == BackgroundStatus.running) {
          state = state.copyWith(
            backgroundStatus: BackgroundStatus.interrupted,
            backgroundSummary: '重跑已中断',
          );
        }
        _backgroundInFlight = false;
        await _persistTokenUsage();
        // 重跑期间又来了新对话:交回自动维护(与主动轮同款补跑)。
        if (!token.cancelled && wake != _backgroundWake) {
          _startPendingMaintenance();
        }
      }
    }
  }

  /// 成功轮记账(`_runBackgroundMaintenance` 与重跑共用):
  /// - 变量真跑了才更新重放窗口(成功但没跑变量的轮次清空,避免重放到过旧区间);
  /// - 有图片任务时作废旧目标、把收集器留给回调逐张填;没图片任务则连旧图一起
  ///   作废 —— 那一轮的图片不再是"最新结果",重跑不该去替换它。
  void _recordMaintenanceWindow(
    BackgroundTurnResult turn,
    List<BackgroundImagePlacement> roundImages,
  ) {
    if (turn.processedAfterSeq != null) {
      _lastMaintenanceAfterSeq = turn.processedAfterSeq;
      _lastMaintenanceThroughSeq = turn.processedThroughSeq;
    } else {
      _lastMaintenanceAfterSeq = null;
      _lastMaintenanceThroughSeq = null;
    }
    _recordMaintenanceImages(turn, roundImages);
  }

  /// 记录本轮图片任务:作废旧替换目标,把收集器交给任务回调逐张填充;
  /// 任务收敛后清空 [_backgroundImageTask],解除对 `/rerun` 的阻塞。
  void _recordMaintenanceImages(
    BackgroundTurnResult turn,
    List<BackgroundImagePlacement> roundImages,
  ) {
    if (turn.imageTask != null) {
      _lastMaintenanceImages = const [];
      final task = turn.imageTask!;
      _backgroundImageTask = task;
      unawaited(
        task.whenComplete(() {
          if (identical(_backgroundImageTask, task)) {
            _backgroundImageTask = null;
          }
        }),
      );
    } else {
      if (identical(_activeImageRecord, roundImages)) _activeImageRecord = null;
      _lastMaintenanceImages = const [];
    }
  }

  /// 没有图片落库的轮次(跳过/失败/中断):解除收集器归属,过期回调不再写记录。
  void _releaseImageRecord(List<BackgroundImagePlacement> roundImages) {
    if (identical(_activeImageRecord, roundImages)) _activeImageRecord = null;
  }

  /// 生图落点回调(自动维护与重跑共用):
  /// - 记进本轮收集器,归属校验通过后同步到 [_lastMaintenanceImages](供下次重跑
  ///   原地替换;替换会改写描述,所以记的正是新描述);
  /// - 原地替换时递增图片修订号(与 regenerateImage 同款),气泡才会换掉缓存的旧图;
  /// - 刷新消息列表;[summaryGuard] 通过时把摘要里的「图片生成中」改成完成文案。
  void Function(BackgroundImagePlacement) _imagePlacementHandler({
    required int sessionId,
    required int epoch,
    required List<BackgroundImagePlacement> roundImages,
    required String replacedText,
    required String appendedText,
    bool Function()? summaryGuard,
  }) => (placement) {
    if (!ref.mounted ||
        state.sessionId != sessionId ||
        _backgroundEpoch != epoch) {
      return;
    }
    roundImages.add(placement);
    if (identical(_activeImageRecord, roundImages)) {
      _lastMaintenanceImages = List.unmodifiable(roundImages);
    }
    if (placement.replaced) {
      state = state.copyWith(
        imageRevisions: {
          ...state.imageRevisions,
          placement.messageId:
              (state.imageRevisions[placement.messageId] ?? 0) + 1,
        },
      );
    }
    unawaited(_refreshMessages());
    if (summaryGuard?.call() ?? true) {
      state = state.copyWith(
        backgroundSummary: state.backgroundSummary.replaceFirst(
          '图片生成中',
          placement.replaced ? replacedText : appendedText,
        ),
      );
    }
  };

  /// 摘要补偿:生图任务与轮次解耦,极快的 provider 可能在成功摘要写回**之前**
  /// 就落库 —— 那时回调改的还是「正在维护…」,完成文案会被随后的摘要覆盖掉。
  /// 已记录的落点非空时,在这里按同款文案把「图片生成中」换成完成态。
  String _settledSummary(
    String summary,
    List<BackgroundImagePlacement> placed, {
    required String replacedText,
  }) {
    if (placed.isEmpty) return summary;
    final done = placed.every((e) => e.replaced) ? replacedText : '图片已生成';
    return summary.replaceFirst('图片生成中', done);
  }

  /// 失败文案拼接诊断摘要:摘要非空时以"(摘要)"附在基础文案后,空则原样返回。
  String _withFailureDetail(String base, String? detail) {
    final d = detail?.trim();
    return (d == null || d.isEmpty) ? base : '$base($d)';
  }

  /// 后台变量落库后失效状态面板相关视图:active 行、回收站、待确认建议。
  void _invalidateVariableViews(int sessionId, BackgroundResult result) {
    ref.invalidate(variablesProvider(sessionId));
    ref.invalidate(variableRowsProvider(sessionId));
    if (result.variableRemovals.isNotEmpty) {
      ref.invalidate(variableTrashProvider(sessionId));
    }
    if (result.variableRemovalProposals.isNotEmpty) {
      ref.invalidate(pendingVariableDeletionsProvider(sessionId));
    }
  }

  /// 由一次后台维护结果拼一句话摘要(用于状态面板/聊天页顶部展示)。
  String _backgroundSummary(BackgroundResult r) {
    final parts = <String>[];
    if (r.variableUpdates.isNotEmpty) {
      parts.add(
        '变量 ${r.variableUpdates.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
      );
    }
    if (r.variableRemovals.isNotEmpty) {
      parts.add('移除变量 ${r.variableRemovals.join(' ')}');
    }
    if (r.variableRemovalProposals.isNotEmpty) {
      parts.add('建议删除变量 ${r.variableRemovalProposals.join(' ')},待确认');
    }
    // 一次多张时只有 imagePrompts(没有单条 imagePrompt),同样要标出「图片
    // 生成中」,否则状态面板看起来像"只更新了变量"。
    if (r.imagePrompt != null || (r.imagePrompts?.isNotEmpty ?? false)) {
      parts.add('图片生成中');
    }
    return parts.isEmpty ? '状态维护完成(无明显变化)' : parts.join(' · ');
  }

  /// 摘要配套的变量改动计数:灵动岛只显示数量,不展开具体键值。
  BackgroundVariableStats _variableStats(BackgroundResult r) =>
      BackgroundVariableStats(
        added: r.addedVariables,
        updated: r.variableUpdates.length - r.addedVariables,
        removed: r.variableRemovals.length,
        proposed: r.variableRemovalProposals.length,
      );

  /// 审计完成摘要:板级计数(区别于维护的逐键 k=v),独立文案。审计不生图,
  /// 故无「图片生成中」段;严格模式删除以「建议删除 K 键待确认」呈现。
  String _auditSummary(BackgroundResult r) {
    final parts = <String>[];
    if (r.variableUpdates.isNotEmpty) {
      parts.add('更新 ${r.variableUpdates.length} 键');
    }
    if (r.variableRemovals.isNotEmpty) {
      parts.add('删除 ${r.variableRemovals.length} 键');
    }
    if (r.variableRemovalProposals.isNotEmpty) {
      parts.add('建议删除 ${r.variableRemovalProposals.length} 键待确认');
    }
    return parts.isEmpty ? '审计完成(无明显变化)' : '审计完成:${parts.join(',')}';
  }
}
