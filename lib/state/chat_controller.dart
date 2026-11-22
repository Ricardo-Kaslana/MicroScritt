/// 聊天页控制器:单会话的发送管线、上下文组装、后台维护与命令入口。
///
/// 控制器按职责拆分在同库 part 文件中(共享私有状态);会话切换经
/// [ChatController.load] 使旧任务失效,`ref.onDispose` 取消两侧中断令牌。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/backend_factory.dart';
import '../backend/image_downloader.dart';
import '../backend/llm_backend.dart';
import '../backend/upstream_error.dart';
import '../models/prompt_item.dart';
import '../context/attachment_budget.dart';
import '../context/context_assembler.dart';
import '../data/image_codec.dart';
import '../data/message_repository.dart';
import '../engine/background_agent.dart';
import '../engine/background_engine.dart';
import '../engine/background_status.dart';
import '../engine/chat_engine.dart';
import '../engine/compact_service.dart';
import '../engine/context_budget.dart';
import '../engine/hook_runtime.dart';
import '../engine/orchestrator.dart';
import '../models/character_card.dart';
import '../models/backend_config.dart';
import '../models/context_snapshot.dart';
import '../models/hook.dart';
import '../models/image_result.dart';
import '../models/app_settings.dart'
    show BackgroundFeatures, BackgroundMode, ReasoningLevel;
import '../models/llm_units.dart';
import '../models/message.dart';
import '../models/skill.dart';
import '../models/token_usage.dart';
import '../models/usage_stats.dart';
import '../models/worldbook_entry.dart';
import 'providers.dart';
import 'interrupt_token.dart';
import 'slash_commands.dart';

// 体量原因按职责拆分在同库 part 文件 —— Dart 的类方法体无法跨库拆分而保持
// 私有成员私有:part 共享库级私有作用域,是把一个有状态控制器拆成多文件而
// 不公开内部状态的唯一无损方式。每个 part 是挂到 [ChatControllerBase]
// (持有全部共享字段)上的一个 mixin。
part 'chat_state.dart';
part 'chat_controller_context.dart';
part 'chat_controller_pipeline.dart';
part 'chat_controller_commands.dart';
part 'chat_controller_session.dart';
part 'chat_controller_background.dart';

/// 单图提示词改写已产出建议、等待用户确认重绘时的状态摘要。第二步只在它
/// 仍是最新摘要时替换为完成文案,避免覆盖期间启动的后台维护摘要。
const String _kImagePromptReadySummary = '新的图片描述已生成,确认后重新生成';

/// [ChatController] 的共享状态基类:全部可变字段(忙碌门控/窗口游标/中断
/// 令牌/记忆冻结副本/后台游标等)集中在此;各 mixin part 携带方法组,
/// 经同库 part 直接访问这些私有字段。
abstract class ChatControllerBase extends Notifier<ChatState> {
  /// 发送/压缩/重生成等命令的互斥门控;流式期间另由 [ChatState.streaming] 拦截。
  bool _busy = false;

  // 组装不再按条数裁剪:组装窗口由「全部未折叠活跃行」界定,见
  // MessageRepository.activeWindow;显示窗口见下方 _historyWindowRows。

  /// 显示窗口行数:进入会话只加载「全部 system 行 + 该尾部」而非全量转录。
  /// 300 条显示行 ≈ 十几屏气泡,覆盖常规会话的浏览主力区间;更早的历史由
  /// 贴顶分页([loadOlder]) 按需补入。
  static const int _historyWindowRows = 300;

  /// 每页向上补入的历史行数。
  static const int _historyPageRows = 120;

  /// 当前窗口下界的 seq(null = 全量在窗,窗口化从未触发)。分页时下移、
  /// 会话切换时重置;元数据刷新([_refreshMessages]/组装输入)都以它为
  /// 下界,保证分页补进来的历史在刷新后仍然在窗。
  int? _windowFloor;

  /// 防并发:loadOlder 进行中不再重入。
  bool _loadingOlder = false;

  /// 契约漂移预警阈值:连续多少轮 contractViolation 判定"上游疑似变更"。
  static const int _contractDriftThreshold = 3;

  /// 主写侧(发送管线,含内联/手动压缩)当前轮的中断令牌。后台侧见
  /// [_backgroundToken]。
  ///
  /// 换发语义:每轮入口换新实例并捕获,轮次终了不复位 —— [InterruptToken]
  /// 的取消对在飞轮不可逆,旧实例随下次换发被 GC。双槽位保证主写与后台并发
  /// 在飞时取消互不干扰:清空一侧不会误伤另一侧,而 [interrupt] 仍可全停。
  InterruptToken _mainToken = InterruptToken();

  /// 后台侧(自动维护与记忆/指导主动轮,彼此串行)当前轮的中断令牌。
  InterruptToken _backgroundToken = InterruptToken();

  /// 备用模型一键切换的目标:主写失败且错误属于"换模型可能有用"的三类
  /// (contentFlag/quota/gatewayPolicy)、当前 provider 还有其它模型时,由
  /// [_offerFallbackModel] 记下 (providerId, modelId);灵动岛横幅的
  /// 「切换备用模型」经 [switchToFallbackModel] 消费。清除错误/新轮开始/
  /// 已执行后置空。
  (int, int)? _fallbackTarget;

  /// 契约漂移预警的连击计数:主写连续以 contractViolation 失败的轮数,
  /// 达到 [_contractDriftThreshold] 时在错误横幅加"疑似变更"导语;成功一轮、
  /// 其它类别失败、清除错误或切换模型即清零。
  int _contractViolationStreak = 0;

  /// 写流式草稿/命令反馈文本(独立 provider,见 [chatDraftProvider])。
  void _setDraft(String value) {
    ref.read(chatDraftProvider.notifier).set(value);
  }

  bool _backgroundInFlight = false;

  /// 消息列表刷新序号:并发刷新(后台追加图片 / 原地替换 / 发送收尾)时只允许
  /// 最新一次查询结果落进 state,晚到的旧快照不得覆盖新图。
  int _messageFetchSeq = 0;

  /// 定位扩窗序号:并发/连点搜索与导航时,只允许最新一次 [revealMessage]
  /// 把显示窗口换成自己的结果。旧请求的 DB 查询晚到时据此作废 —— 否则
  /// 后发请求已把窗口移到目标 B,先发请求晚到的 `bySessionSince(A)` 还会
  /// 再把窗口改回 A,随后定位循环找不到 B,表现为「跳转抖动且到不了」。
  int _revealWindowSeq = 0;

  /// 会话装载代次:图片重新生成在写库前据此识别会话切换(A→B→A 也能区分)。
  int _sessionEpoch = 0;

  /// 最近一轮后台维护任务;测试可 await 它等待后台轮收敛后再断言状态。
  @visibleForTesting
  Future<void>? backgroundTask;

  /// hybrid 周期审计计数器(per-session 内存态,不跨重启):仅成功且变量真应用
  /// (cursorSeq != null)的旧维护轮 +1,达 [AuditProfile.auditInterval] 触发审计。
  /// 切会话([load])清零;审计成败/冲突/良性跳过重置,让位/取消不重置(稍后重试);
  /// rerun 与历史改写不计数也不重置(节奏启发式,非正确性不变量)。
  int _auditCounter = 0;

  /// 当前在飞轮是否为审计:让位判定用。不变量 —— `_auditRunning == true` 蕴含
  /// 审计持有当前 [_backgroundToken] 且 [_backgroundInFlight] 为真;其余换发点
  /// (memory/rerun/维护)都被 inFlight 门控挡在审计之外,[interrupt] 不换发,
  /// [_invalidateBackground] 是唯一旁路,故它必须同步清此标志(防残留误让位)。
  bool _auditRunning = false;

  /// 后台变量维护的进度游标(已处理到的 seq);null 表示本周期尚未起步。
  int? _backgroundCursorSeq;

  /// 本周期首次触发时固定的基线 seq:只回看最近三条,不把重入前的古老历史
  /// 当成未处理;失败轮保持不变。
  int? _backgroundBaselineSeq;

  /// 本轮后台维护应处理到的对话尾部 seq。
  int? _backgroundTargetSeq;

  /// 会话/历史代数:每次 [_invalidateBackground] 自增,在飞轮据此识别自己已过期。
  int _backgroundEpoch = 0;

  /// 后台轮唤醒号:每次触发维护自增。在飞轮结束时不相等即有新对话到达,
  /// 合并为待处理并在当前轮收敛后续跑,而不是并发开新轮。
  int _backgroundWake = 0;

  /// 生图唤醒号:只为最新一次生图请求结算;过期轮的回调不覆盖摘要与状态。
  int _backgroundImageWake = 0;

  /// 变量维护待处理标志:在飞轮结束后据此续跑(单次最多两轮)。
  bool _backgroundPending = false;

  /// 生图维护待处理标志:置位后当前轮必须消费。
  bool _backgroundPendingImage = false;

  /// `/rerun` 重跑用的**上次成功维护**记录(会话内存态,不跨重启):
  /// - 窗口:那一轮实际送给后台的对话区间(afterSeq 之后到 throughSeq,含)。
  ///   成功但没跑变量的轮次会清空,避免重跑到过旧的区间上。
  /// - 图片:那一轮落库的图片落点([BackgroundImagePlacement],prompt 是写入时的
  ///   描述,替换会改写它,所以它同时是下次条件更新的期望值),重跑按位置原地
  ///   替换,聊天流不堆重复图片。
  /// 会话切换/历史改写经 [_invalidateBackground] 一并失效。
  int? _lastMaintenanceAfterSeq;
  int? _lastMaintenanceThroughSeq;
  List<BackgroundImagePlacement> _lastMaintenanceImages = const [];

  /// 当前轮的图片落点收集器:生图任务与轮次解耦,回调可能早于 runAfterTurn
  /// 返回;按 identical 判定归属,过期轮的回调不写进 [_lastMaintenanceImages]。
  List<BackgroundImagePlacement>? _activeImageRecord;

  /// 在飞的后台生图任务:收敛前拒绝 `/rerun`(避免两个写入者争同一替换目标,
  /// 也避免目标 id 还没记录完)。
  Future<void>? _backgroundImageTask;

  /// 使后台任务整体失效(会话切换/历史改写):递增代数并取消令牌,清空
  /// 游标、待处理标志与 `/rerun` 记录;正在跑的后台轮因归属校验失败而丢弃结果。
  void _invalidateBackground() {
    _backgroundEpoch++;
    _backgroundToken.cancel();
    _backgroundToken = InterruptToken();
    _backgroundInFlight = false;
    // 审计在飞时历史改写/切会话:旧审计 finally 可能尚未收敛,若不清此标志,
    // 随后新维护在飞 + 残留 true 会让 fire 误走让位分支 cancel 无辜的新令牌。
    // 计数器不清(节奏启发式);切会话的清零在 load 链内单独做。
    _auditRunning = false;
    _backgroundCursorSeq = null;
    _backgroundBaselineSeq = null;
    _backgroundTargetSeq = null;
    _backgroundPending = false;
    _backgroundPendingImage = false;
    _pendingVariableInjection = null;
    _lastMaintenanceAfterSeq = null;
    _lastMaintenanceThroughSeq = null;
    _lastMaintenanceImages = const [];
    _activeImageRecord = null;
    _backgroundImageTask = null;
    if (ref.mounted) {
      if (state.backgroundStatus == BackgroundStatus.running) {
        state = state.copyWith(
          backgroundStatus: BackgroundStatus.interrupted,
          backgroundSummary: '后台维护已中断',
          nextSuggestions: const [],
        );
      } else if (state.nextSuggestions.isNotEmpty) {
        state = state.copyWith(nextSuggestions: const []);
      }
    }
  }

  /// 在飞后台轮是否仍归当前会话所有:会话相同、代数未变、令牌实例一致
  /// 三者同时成立才允许写状态与落库。
  bool _ownsBackground(int sessionId, int epoch, InterruptToken token) =>
      ref.mounted &&
      state.sessionId == sessionId &&
      _backgroundEpoch == epoch &&
      identical(_backgroundToken, token);

  /// 主写/上下文写点的归属判定:会话与代次一致才允许写 UI 状态、触发后台。
  /// 切换会话时 [load] 递增代数并取消主写令牌,在飞轮随后据此丢弃结果;
  /// 数据库写仍使用调用方捕获的 sessionId,不会写错库。
  bool _ownsMain(int sessionId, int epoch) =>
      ref.mounted && _sessionEpoch == epoch && state.sessionId == sessionId;

  /// 生效中的记忆冻结副本:组装"第 0 条消息"用的文本。
  ///
  /// 冻结语义保证提示缓存前缀稳定:
  /// - [load] 时取库中当前值,此后会话进行中**轻易不变** —— 即使记忆在库中
  ///   被修改(手动编辑/主动重生成),这里也保持旧字节,改动以一次性 diff
  ///   通知送达(见 `_memoryDiffNotice`),不扰动第 0 条及其后历史的缓存前缀;
  /// - 只在两处刷新:压缩触发后(压缩本身就是缓存断点,顺带换新记忆)、用户
  ///   主动点击「应用到上下文」([applyMemoryToContext])。
  String? _frozenMemory;

  /// 压缩通知待发标志:**仅硬挡路径**使用——硬挡压缩发生在发送管线内、用户
  /// 消息已落库,当轮由 [_persistPendingNotices] 落库为附件行并复位。
  /// 手动 `/compact` 与软挡压缩在完成时立即落库通知,不经过本标志
  /// (延迟到下一次输入会在切换会话时丢失)。
  bool _compactNoticePending = false;

  /// 已发送过 diff 通知的记忆版本(库中内容哈希):同一版本不重复发 diff;
  /// 库内容再变(哈希不同)时下一次输入再发一次。null 表示尚无已通知版本。
  int? _memoryDiffNotifiedHash;

  /// 后台 Agentic 待注入主写上下文的变量快照(键 → 提交后最终值)。
  /// 在下一条用户消息落库前由 [_persistPendingVariableInjection] 消费为
  /// 附件行;切会话/历史改写/重跑入口清空,避免陈旧快照复活。
  Map<String, String>? _pendingVariableInjection;

  /// 中断当前正在进行的生成:主写流式被截断(已生成的部分文本落库保留),
  /// 后台维护被跳过。
  /// 主写与后台可并发在飞(各持自己的令牌),两侧同时打断;无在飞轮时是
  /// 无害的空操作(下一轮入口本就换新实例,取消不会泄漏)。
  void interrupt() {
    _mainToken.cancel();
    _backgroundToken.cancel();
    _backgroundPending = false;
    _backgroundPendingImage = false;
    // 在没有在飞后台轮的早退残局里,状态可能停在 running 而 finally 已跑完;
    // 此时停止键必须能立即把状态收敛,不能留下幽灵「维护中」。
    if (ref.mounted &&
        !_backgroundInFlight &&
        state.backgroundStatus == BackgroundStatus.running) {
      state = state.copyWith(
        backgroundStatus: BackgroundStatus.interrupted,
        backgroundSummary: '后台维护已中断',
        nextSuggestions: const [],
      );
    }
  }

  /// 关闭/忽略下一步建议底单:丢弃本批(纯内存,下次后台轮重新生成)。
  void dismissNextSuggestions() {
    if (!ref.mounted || state.nextSuggestions.isEmpty) return;
    state = state.copyWith(nextSuggestions: const []);
  }

  /// 是否有一条正在进行的主写回复可被中断(流式中、后台维护中或压缩中)。
  /// 压缩中(busyCommand)覆盖 /compact、软挡自动压缩与硬挡内联压缩 —— 三者
  /// 都响应 [interrupt]。
  bool get canInterrupt =>
      state.streaming ||
      state.backgroundStatus == BackgroundStatus.running ||
      state.busyCommand != null;

  /// 压缩摘要(compact)调用的 token 用量累加进会话的第三桶记账。
  /// 压缩在发送管线内联执行,频率低、用量小,单独记账不与主写/后台混淆。
  /// (发送管线与命令层都用 —— 放共享基类,继承链各层可见。)
  ///
  /// [sessionId]/[epoch] 由调用方捕获:压缩请求可能在切会话后收尾,用量仍应
  /// 记到发起压缩的会话,而 UI 桶只在归属未变时才允许写当前状态。
  void _accumulateCompactUsage(TokenUsage usage, {int? sessionId, int? epoch}) {
    final target = sessionId ?? state.sessionId;
    final owned =
        target != null &&
        state.sessionId == target &&
        (epoch == null || _sessionEpoch == epoch);
    if (owned) {
      state = state.copyWith(
        compactInputTokens: state.compactInputTokens + usage.inputTokens,
        compactOutputTokens: state.compactOutputTokens + usage.outputTokens,
        compactCachedInputTokens:
            state.compactCachedInputTokens + usage.cachedInputTokens,
      );
    }
    // 摘要每次尝试都回调一次(含上游未上报全零):计入逐请求统计的请求次数。
    unawaited(
      _recordUsage(
        sessionId: target,
        kind: UsageKind.compact,
        config: ref.read(backendConfigProvider),
        usage: usage,
        reported: usage.hasAny,
      ),
    );
  }

  /// 记录一次业务生成的 token 用量(统计面板的 append-only 明细)。
  ///
  /// 记账是附加信息:会话/配置缺失或写库失败都静默跳过,不影响主流程。
  Future<void> _recordUsage({
    required int? sessionId,
    required UsageKind kind,
    required BackendConfig? config,
    required TokenUsage usage,
    required bool reported,
  }) async {
    if (!ref.mounted || sessionId == null || config == null) return;
    try {
      await ref
          .read(usageRepositoryProvider)
          .record(
            sessionId: sessionId,
            kind: kind,
            providerId: config.providerId,
            providerName: config.providerName.isEmpty
                ? config.providerWire
                : config.providerName,
            model: config.model,
            modelName: config.modelName.isEmpty
                ? config.model
                : config.modelName,
            usage: usage,
            reported: reported,
          );
    } catch (_) {}
  }

  /// 活跃可达行(含附件):压缩预算必须把它们一起算,否则保留的对话行
  /// 会连同其世界书/技能附件超预算。
  List<Message> _activeRows(List<Message> all) => all
      .where(
        (m) => m.role != 'system' && !m.isCompacted && m.content.isNotEmpty,
      )
      .toList();
}

/// 聊天页控制器:继承链 Base(共享字段)→ Context(组装)→ Session(会话)
/// → Background(后台)→ Pipeline(发送)→ Commands(命令) —— 每层只依赖更早
/// 的层,方法组间的互调方向与依赖顺序一致;同库 part 让全链共享私有字段。
class ChatController extends ChatControllerCommands {
  /// 创建空状态;容器销毁时取消主写与后台的中断令牌,避免在飞轮继续写状态。
  @override
  ChatState build() {
    ref.onDispose(() {
      _mainToken.cancel();
      _backgroundToken.cancel();
    });
    return const ChatState();
  }

  /// 把输入中的 @技能名 记号从 LLM 可见文本剥离的共享实现(组装出口用,
  /// 逻辑在 [ContextAssembler.withoutSkillTokens];保留静态入口供测试 ——
  /// static 不随继承下传,必须声明在测试引用的本类上)。
  @visibleForTesting
  static String stripSkillTokens(String text, Iterable<Skill> skills) =>
      ContextAssembler.withoutSkillTokens(text, skills.map((s) => s.name));
}

/// 聊天页的控制器与状态;应用级单例(非 autoDispose),会话切换由
/// [ChatController.load] 重置,容器销毁时取消在飞轮。
final chatControllerProvider = NotifierProvider<ChatController, ChatState>(
  ChatController.new,
);
