// 制卡草稿编解码测试:紧凑卡 DTO、负临时 id/extra、决策、日志与坏数据回落。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/card_studio/card_diff.dart';
import 'package:microscritt/models/bubble_style.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';
import 'package:microscritt/state/card_studio_draft_codec.dart';
import 'package:microscritt/state/card_studio_state.dart';

void main() {
  CharacterCard baseCard() => const CharacterCard(
        name: '旧名',
        description: '旧描述',
        personality: '旧性格',
        scenario: '旧场景',
        firstMessage: '旧开场',
        mesExample: '旧示例',
        systemPrompt: '旧系统',
        postHistoryInstructions: '旧后指令',
        creatorNotes: '旧备注',
        depthPrompt: '旧深度',
        alternateGreetings: ['g1'],
        tags: ['t1'],
        creator: 'author',
        characterVersion: '1.0',
        talkativeness: 'chatty',
        fav: true,
        bubbleStyle: BubbleStyle(bubbleColor: 0xFF112233, radius: 20),
        avatarBase64: 'avatar-base',
        backgroundBase64: 'bg-base',
      );

  CharacterCard draftCard() => const CharacterCard(
        name: '新名',
        description: '新描述',
        personality: '新性格',
        scenario: '新场景',
        firstMessage: '新开场',
        mesExample: '新示例',
        systemPrompt: '新系统',
        postHistoryInstructions: '新后指令',
        creatorNotes: '新备注',
        depthPrompt: '新深度',
        alternateGreetings: ['g1', 'g2'],
        tags: ['t1', 't2'],
        creator: 'author',
        characterVersion: '1.0',
        talkativeness: 'chatty',
        fav: true,
        bubbleStyle: BubbleStyle(bubbleColor: 0xFF112233, radius: 20),
        avatarBase64: 'new-avatar',
        backgroundBase64: 'bg-base',
      );

  WorldbookEntry baseEntry() => const WorldbookEntry(
        id: 4,
        characterId: 7,
        name: '设定',
        keys: ['蒸汽'],
        secondaryKeys: ['城'],
        content: '旧内容',
        constant: true,
        selective: true,
        position: 2,
        enabled: false,
        background: true,
        extra: {'probability': 80},
      );

  WorldbookEntry newEntry() => const WorldbookEntry(
        id: -1,
        characterId: 7,
        name: '新增',
        keys: ['新'],
        content: '新增内容',
        position: 3,
        extra: {'custom': true},
      );

  CardStudioDraftSnapshot snapshot() => CardStudioDraftSnapshot(
        targetCharacterId: 7,
        baseCard: baseCard(),
        baseEntries: [baseEntry()],
        draftCard: draftCard(),
        draftEntries: [
          baseEntry().copyWith(content: '新内容'),
          newEntry(),
        ],
        decisions: ReviewDecisions.acceptAll
            .withField('name', const FieldDecision(editedText: '编辑名'))
            .withEntry(
              'base:4',
              EntryDecision(
                editedEntry: baseEntry().copyWith(content: '手工内容'),
              ),
            )
            .withEntry('new:-1', const EntryDecision(accepted: false))
            .withAvatar(false),
        entries: const [
          CardStudioEntry.user('写卡'),
          CardStudioEntry(CardStudioEntryKind.agent, '构思', step: 2),
          CardStudioEntry(
            CardStudioEntryKind.toolStep,
            '更新角色卡',
            tools: ['setCardFields'],
            step: 3,
          ),
          CardStudioEntry.notice('完成'),
          CardStudioEntry.error('失败'),
        ],
        sessionLog: const ['用户：写卡', '完成：ok'],
        draftAvatarPrompt: '1girl, red hair',
        generatedAvatarPrompt: '1girl, red hair',
        lastSummary: 'ok',
        lastRequestInputTokens: 1800,
        lastRequestCachedInputTokens: 1500,
        contextEstimateTokens: 240,
      );

  test('round-trips cards, entries, decisions and logs', () {
    final payload = jsonDecode(jsonEncode(encodeCardStudioDraft(snapshot())))
        as Map<String, dynamic>;
    final restored = decodeCardStudioDraft(payload)!;

    expect(restored.targetCharacterId, 7);
    expect(restored.baseCard.name, '旧名');
    expect(restored.baseCard.avatarBase64, 'avatar-base');
    expect(restored.baseCard.backgroundBase64, 'bg-base');
    expect(restored.baseCard.fav, isTrue);
    expect(restored.baseCard.bubbleStyle?.bubbleColor, 0xFF112233);
    expect(restored.baseCard.raw, isEmpty, reason: '草稿不落 raw');
    expect(restored.draftCard.name, '新名');
    expect(restored.draftCard.avatarBase64, 'new-avatar');
    expect(restored.draftCard.alternateGreetings, ['g1', 'g2']);

    final base = restored.baseEntries.single;
    expect(base.id, 4);
    expect(base.position, 2);
    expect(base.enabled, isFalse);
    expect(base.background, isTrue);
    expect(base.extra, {'probability': 80});
    expect(restored.draftEntries.map((e) => e.id), [4, -1]);
    expect(restored.draftEntries.last.extra, {'custom': true});

    expect(restored.decisions.field('name').editedText, '编辑名');
    expect(
      restored.decisions.entry('base:4').editedEntry?.content,
      '手工内容',
    );
    expect(restored.decisions.entry('new:-1').accepted, isFalse);
    expect(restored.decisions.avatarAccepted, isFalse);

    expect(restored.entries.map((e) => e.kind), [
      CardStudioEntryKind.user,
      CardStudioEntryKind.agent,
      CardStudioEntryKind.toolStep,
      CardStudioEntryKind.notice,
      CardStudioEntryKind.error,
    ]);
    expect(restored.entries[2].tools, ['setCardFields']);
    expect(restored.entries[2].step, 3);
    expect(restored.sessionLog, ['用户：写卡', '完成：ok']);
    expect(restored.draftAvatarPrompt, '1girl, red hair');
    expect(restored.generatedAvatarPrompt, '1girl, red hair');
    expect(restored.lastSummary, 'ok');
    expect(restored.lastRequestInputTokens, 1800);
    expect(restored.lastRequestCachedInputTokens, 1500);
    expect(restored.contextEstimateTokens, 240);
  });

  test('withRaw attaches the current envelope without touching fields', () {
    final card = baseCard().withRaw({'spec': 'chara_card_v2', 'data': {}});
    expect(card.raw, {'spec': 'chara_card_v2', 'data': {}});
    expect(card.name, '旧名');
    expect(card.avatarBase64, 'avatar-base');
    expect(card.backgroundBase64, 'bg-base');
    expect(card.bubbleStyle?.radius, 20);
  });

  test('malformed payloads decode to null', () {
    expect(decodeCardStudioDraft({'target': 'x'}), isNull);
    expect(decodeCardStudioDraft({'target': 7}), isNull);

    Map<String, dynamic> payload() =>
        jsonDecode(jsonEncode(encodeCardStudioDraft(snapshot())))
            as Map<String, dynamic>;

    final noDraft = payload()..remove('draft');
    expect(decodeCardStudioDraft(noDraft), isNull);

    final badKind = payload();
    badKind['entries'] = [
      {'kind': 'unknown', 'text': 'x'},
    ];
    expect(decodeCardStudioDraft(badKind), isNull);

    final badEntry = payload();
    badEntry['base'] = {
      'card': encodeCardStudioDraft(snapshot())['base']['card'],
      'entries': [
        {'id': 1},
      ],
    };
    expect(decodeCardStudioDraft(badEntry), isNull);

    final badUsage = payload()
      ..['lastRequestInputTokens'] = 'bad'
      ..['lastRequestCachedInputTokens'] = -1
      ..['contextEstimateTokens'] = null;
    final restoredUsage = decodeCardStudioDraft(badUsage);
    expect(restoredUsage, isNotNull, reason: '坏用量只回落,不丢整份草稿');
    expect(restoredUsage!.lastRequestInputTokens, isNull);
    expect(restoredUsage.lastRequestCachedInputTokens, 0);
    expect(restoredUsage.contextEstimateTokens, 0);
  });
}
