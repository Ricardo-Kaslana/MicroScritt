part of 'chat_controller.dart';

/// 协作式中断令牌:主写引擎与后台agent 共用同一驱动取消的通道。
/// 双通道语义 —— 轮询([cancelled],每消费一个事件/每步状态写入前检查,后台
/// 引擎的 shouldCancel 用)+ 即时通知([whenCancelled],让"等待首个流事件"
/// 的消费者在零事件期也能被立即唤醒)。
///
/// 令牌**不可复用**(EF 批):没有 reset。"供下一轮使用"靠控制器每轮入口
/// 换发新实例(主写/后台双槽位,见 ChatController 字段注释)。在飞轮持有
/// 自己的实例,其 cancelled 永真;若在实例上清标志(旧 reset),会把**另一
/// 条还在飞的轮**(后台维护常与下一轮主写并发)的取消通道一并吹灭 —— 用户
/// 按了停止,后台轮却因标志被清而继续跑完并写状态。
class InterruptToken {
  bool _cancelled = false;
  Completer<void>? _completer;
  bool get cancelled => _cancelled;

  /// 下一次 [cancel] 发生时完成的 Future;已取消时立即完成。
  /// 仅用于"睡眠中等待"的竞速唤醒,轮询检查仍走 [cancelled]。
  Future<void> get whenCancelled =>
      _cancelled ? Future.value() : (_completer ??= Completer<void>()).future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _completer?.complete();
    _completer = null;
  }
}

class ChatState {
  final int? sessionId;
  final int? characterId;
  final CharacterCard? character;
  final List<Message> messages;

  /// [messages] 这份转录归属的会话 id。与 [sessionId] 的区别只在 load 的
  /// 切换窗口内有意义:元数据清空后 [sessionId] 为 null,但转录按 DR 批的
  /// 原子切换语义被暂存 —— 本字段记下暂存转录真正属于谁,UI 据此区分
  /// 「切往其它会话时的旧转录(须隐藏,防串味)」与「重进同一会话时暂存的
  /// 就是本屏会话的转录(内容与新窗口一致,照常显示,不得再触发隐藏)」。
  final int? transcriptSessionId;
  final List<WorldbookEntry> worldbook;
  final bool streaming;
  final String? error;

  /// 备用模型建议(P1 契约层):生成失败且错误属于"换模型可能有用"
  /// (contentFlag/quota/gatewayPolicy)、当前 provider 目录还有其它模型时,
  /// 控制器在此放入备用模型的展示名 —— 灵动岛错误横幅随之给出「切换备用
  /// 模型」一键动作。null = 无建议(错误不可换模型修复/没有其它模型)。
  /// 切换执行、清除错误或开始新一轮生成时置空。
  final String? fallbackModelHint;

  /// 契约漂移预警(P2):主写连续 ≥3 轮以 contractViolation 失败时置位 ——
  /// 上游协议疑似变更,横幅在错误原文前加"疑似变更"导语提示用户用分级探测
  /// 复核。成功一轮、其它类别失败、清除错误或一键切换模型时复位。
  final bool contractDriftWarning;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int backgroundInputTokens;
  final int backgroundOutputTokens;
  final int backgroundCachedInputTokens;

  /// 压缩摘要(compact)调用的 token 用量,与主写/后台分开记账(D2)。
  final int compactInputTokens;
  final int compactOutputTokens;
  final int compactCachedInputTokens;

  /// 后台agent 最近一轮的运行状态(状态面板/聊天页顶部展示)。
  final BackgroundStatus backgroundStatus;

  /// 后台agent 最近一轮维护的一句话摘要(如"新增技能 战斗 · 变量 hp→9")。
  final String backgroundSummary;

  /// 最近一次组装出的上下文快照(发送时更新;load 时给出基线预览)。
  /// 供上下文面板实时展示分段组成与消息数。
  final ContextSnapshot? lastContext;

  /// 上下文当前冻结的"第 0 条记忆"(null = 上下文无记忆)。库中记忆被改写后
  /// 这里仍是旧版本,直到压缩或用户主动「应用到上下文」才整体换新;状态面板
  /// 据此高亮应用入口,提醒还有未应用的修改。
  final String? frozenMemory;

  /// 上一轮的稳定 system 前缀哈希([lastContext.stableSystemHash] 的上一次取值)。
  /// 上下文面板据此与当前快照比对,提示"稳定前缀本轮未变化(可缓存命中)"或
  /// "稳定前缀已变化(缓存区漂移)"。null 表示尚无上一轮(首轮/刚加载)。
  final int? prevStableSystemHash;

  /// 最近一次主写请求的**实际输入 token**(服务端 UsageEvent 计数,精确值)。
  /// 供上下文使用率圆环作真实锚点 —— 字符估算(÷3.2)只在无锚点时兜底。
  ///
  /// null = 尚无真实锚点:尚未发送过,或网关一直未上报用量。**一旦拿到真实值
  /// 就尽量沿用**:编辑/删除单条消息、删图、记忆应用到上下文这类局部改写不再
  /// 清空锚点(改动通常远小于字符估算的误差);只有上下文被整体重写(`/clear`、
  /// `/compact`)才失效 —— 那时旧值对下一次请求已无意义。随每轮主写请求完成而
  /// 重锚;会话行的 `input_tokens` 同为"最近一轮"口径,load 时据此恢复。
  final int? lastSentInputTokens;

  /// 消息窗口之上是否还有更早的历史(DV 批窗口化加载):true 时聊天页贴顶
  /// 触发 [ChatController.loadOlder] 向上分页。会话全部消息装进窗口时为
  /// false(绝大多数会话如此,行为与全量加载完全一致)。
  final bool canLoadOlder;

  /// 正在向上补页(列表远端的「正在加载更早消息」行)。与 [canLoadOlder]
  /// 分开:后者表示"还有更早历史",前者表示"这一页正在读库"。
  final bool loadingOlder;

  /// 正在重新生成图片的消息 id(null = 空闲)。单张串行:生成期间操作行
  /// 拒绝重复触发,气泡图片叠加转圈遮罩。
  final int? regeneratingImageId;

  /// 各消息图片内容的本地修订号:每次原地替换后递增,气泡据此绕过旧解码
  /// 缓存重新读库(库里的图片/描述不变时保持原值)。
  final Map<int, int> imageRevisions;

  /// 耗时命令进行中的标识(当前仅 'compact'):/compact、软挡自动压缩与发送
  /// 管线内的硬挡压缩在 LLM 摘要期间置位 —— 灵岛进入「压缩中」活动态、发送
  /// 键切换为可中断(压缩请求响应取消信号,网络黑洞时用户不再是"连停止键
  /// 都没有")。null = 无耗时命令在飞。
  final String? busyCommand;

  const ChatState({
    this.sessionId,
    this.characterId,
    this.character,
    this.messages = const [],
    this.transcriptSessionId,
    this.worldbook = const [],
    this.streaming = false,
    this.error,
    this.fallbackModelHint,
    this.contractDriftWarning = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.backgroundInputTokens = 0,
    this.backgroundOutputTokens = 0,
    this.backgroundCachedInputTokens = 0,
    this.compactInputTokens = 0,
    this.compactOutputTokens = 0,
    this.compactCachedInputTokens = 0,
    this.backgroundStatus = BackgroundStatus.idle,
    this.backgroundSummary = '',
    this.lastContext,
    this.frozenMemory,
    this.lastSentInputTokens,
    this.canLoadOlder = false,
    this.loadingOlder = false,
    this.prevStableSystemHash,
    this.regeneratingImageId,
    this.imageRevisions = const {},
    this.busyCommand,
  });

  // Sentinel so `copyWith(error: null)` can clear a previously set error.
  static const _unset = Object();

  ChatState copyWith({
    int? sessionId,
    int? characterId,
    CharacterCard? character,
    List<Message>? messages,
    int? transcriptSessionId,
    List<WorldbookEntry>? worldbook,
    bool? streaming,
    Object? error = _unset,
    Object? fallbackModelHint = _unset,
    bool? contractDriftWarning,
    int? inputTokens,
    int? outputTokens,
    int? cachedInputTokens,
    int? backgroundInputTokens,
    int? backgroundOutputTokens,
    int? backgroundCachedInputTokens,
    int? compactInputTokens,
    int? compactOutputTokens,
    int? compactCachedInputTokens,
    BackgroundStatus? backgroundStatus,
    String? backgroundSummary,
    ContextSnapshot? lastContext,
    Object? frozenMemory = _unset,
    Object? lastSentInputTokens = _unset,
    bool? canLoadOlder,
    bool? loadingOlder,
    Object? prevStableSystemHash = _unset,
    Object? regeneratingImageId = _unset,
    Map<int, int>? imageRevisions,
    Object? busyCommand = _unset,
  }) => ChatState(
    sessionId: sessionId ?? this.sessionId,
    characterId: characterId ?? this.characterId,
    character: character ?? this.character,
    messages: messages ?? this.messages,
    transcriptSessionId: transcriptSessionId ?? this.transcriptSessionId,
    worldbook: worldbook ?? this.worldbook,
    streaming: streaming ?? this.streaming,
    error: identical(error, _unset) ? this.error : error as String?,
    fallbackModelHint: identical(fallbackModelHint, _unset)
        ? this.fallbackModelHint
        : fallbackModelHint as String?,
    contractDriftWarning: contractDriftWarning ?? this.contractDriftWarning,
    inputTokens: inputTokens ?? this.inputTokens,
    outputTokens: outputTokens ?? this.outputTokens,
    cachedInputTokens: cachedInputTokens ?? this.cachedInputTokens,
    backgroundInputTokens: backgroundInputTokens ?? this.backgroundInputTokens,
    backgroundOutputTokens:
        backgroundOutputTokens ?? this.backgroundOutputTokens,
    backgroundCachedInputTokens:
        backgroundCachedInputTokens ?? this.backgroundCachedInputTokens,
    compactInputTokens: compactInputTokens ?? this.compactInputTokens,
    compactOutputTokens: compactOutputTokens ?? this.compactOutputTokens,
    compactCachedInputTokens:
        compactCachedInputTokens ?? this.compactCachedInputTokens,
    backgroundStatus: backgroundStatus ?? this.backgroundStatus,
    backgroundSummary: backgroundSummary ?? this.backgroundSummary,
    lastContext: lastContext ?? this.lastContext,
    frozenMemory: identical(frozenMemory, _unset)
        ? this.frozenMemory
        : frozenMemory as String?,
    lastSentInputTokens: identical(lastSentInputTokens, _unset)
        ? this.lastSentInputTokens
        : lastSentInputTokens as int?,
    canLoadOlder: canLoadOlder ?? this.canLoadOlder,
    loadingOlder: loadingOlder ?? this.loadingOlder,
    prevStableSystemHash: identical(prevStableSystemHash, _unset)
        ? this.prevStableSystemHash
        : prevStableSystemHash as int?,
    regeneratingImageId: identical(regeneratingImageId, _unset)
        ? this.regeneratingImageId
        : regeneratingImageId as int?,
    imageRevisions: imageRevisions ?? this.imageRevisions,
    busyCommand: identical(busyCommand, _unset)
        ? this.busyCommand
        : busyCommand as String?,
  );
}

/// 流式草稿/命令反馈文本的独立 provider(EF 批,自 ChatState 拆出)。
/// 它是全状态里唯一的高频字段(流式期间约 25FPS 一刷),而消费面很窄 ——
/// 只有消息列表的"生成中气泡"与贴底跟随逻辑。独立之后,chat_screen 的页面级
/// watch 不再被它拖着走:每个流式块只重建消息列表一小块,AppBar/输入区/
/// 灵动岛/上下文面板整页陪跑重建的历史就此结束。会话切换时由 [ChatController.load] 清零。
class ChatDraftNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final chatDraftProvider = NotifierProvider<ChatDraftNotifier, String>(
  ChatDraftNotifier.new,
);
