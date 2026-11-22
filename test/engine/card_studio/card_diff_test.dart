// 制卡 diff 测试:行级 LCS/降级/折叠、卡片与世界书对账、决策合成与校验。
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/engine/card_studio/card_diff.dart';
import 'package:microscritt/models/character_card.dart';
import 'package:microscritt/models/worldbook_entry.dart';

void main() {
  group('diffText', () {
    test('identical text yields all same lines', () {
      final diff = diffText('a\nb', 'a\nb');
      expect(diff.hasChanges, isFalse);
      expect(diff.lines.map((l) => l.kind), everyElement(DiffLineKind.same));
    });

    test('insertion and deletion at edges', () {
      expect(diffText('', 'x').lines.single.kind, DiffLineKind.added);
      expect(diffText('x', '').lines.single.kind, DiffLineKind.removed);
      final d = diffText('a\nb', 'a\nb\nc');
      expect(d.lines.map((l) => (l.kind, l.text)), [
        (DiffLineKind.same, 'a'),
        (DiffLineKind.same, 'b'),
        (DiffLineKind.added, 'c'),
      ]);
    });

    test('replacement renders removals before additions', () {
      final d = diffText('a\nold\nz', 'a\nnew\nz');
      expect(d.lines.map((l) => (l.kind, l.text)), [
        (DiffLineKind.same, 'a'),
        (DiffLineKind.removed, 'old'),
        (DiffLineKind.added, 'new'),
        (DiffLineKind.same, 'z'),
      ]);
    });

    test('CRLF is normalized', () {
      expect(diffText('a\r\nb', 'a\nb').hasChanges, isFalse);
    });

    test('oversized diff degrades to whole-block replacement', () {
      final oldLines = List.generate(201, (i) => 'o$i');
      final newLines = List.generate(201, (i) => 'n$i');
      final d = diffText(oldLines.join('\n'), newLines.join('\n'));
      expect(d.removedCount, 201);
      expect(d.addedCount, 201);
      // 降级时先全部删除再全部新增。
      expect(d.lines.first.kind, DiffLineKind.removed);
      expect(d.lines.last.kind, DiffLineKind.added);
    });
  });

  group('foldDiffLines', () {
    test('no changes renders nothing', () {
      expect(foldDiffLines(diffText('a', 'a')), isEmpty);
    });

    test('collapses long unchanged runs but keeps context', () {
      final oldText = List.generate(30, (i) => 'line$i').join('\n');
      final newText = oldText.replaceFirst('line15', 'changed');
      final folded = foldDiffLines(diffText(oldText, newText), context: 2);
      expect(folded.any((l) => l.collapsedCount != null), isTrue);
      expect(
        folded.any((l) => l.text == 'changed' && l.kind == DiffLineKind.added),
        isTrue,
      );
      final texts = folded.map((l) => l.text).toList();
      // 变化行（删除 line15 + 新增 changed）前后各保留 2 行上下文。
      expect(
        texts,
        containsAll(['line13', 'line14', 'line15', 'line16', 'line17']),
      );
      expect(texts, isNot(contains('line0')));
    });
  });

  group('computeCardDiff', () {
    CharacterCard base() => const CharacterCard(
      name: 'A',
      description: 'old\ndesc',
      tags: ['t1'],
      avatarHash: 'old-avatar',
    );

    CharacterCard draftWith({
      String name = 'A',
      String description = 'old\ndesc',
      List<String> tags = const ['t1'],
      String? avatar = 'old-avatar',
    }) => CharacterCard(
      name: name,
      description: description,
      tags: tags,
      avatarHash: avatar,
    );

    WorldbookEntry entry(int id, String content, {String name = 'E'}) =>
        WorldbookEntry(
          id: id,
          characterId: 1,
          name: name,
          keys: const ['k'],
          content: content,
          position: id,
        );

    test(
      'field, entry and avatar changes are detected; untouched entries skipped',
      () {
        final baseEntries = [entry(1, 'same'), entry(2, 'old')];
        final draftCard = draftWith(
          name: 'B',
          description: 'new\ndesc',
          avatar: 'new-avatar',
        );
        final draftEntries = [
          baseEntries.first,
          baseEntries[1].copyWith(content: 'new'),
          const WorldbookEntry(
            characterId: 1,
            id: -1,
            name: 'New',
            keys: ['n'],
            content: 'x',
          ),
        ];

        final diff = computeCardDiff(
          baseCard: base(),
          baseEntries: baseEntries,
          draftCard: draftCard,
          draftEntries: draftEntries,
        );

        expect(diff.fields.map((f) => f.key), ['name', 'description']);
        expect(diff.entries.map((e) => e.kind), [
          WorldbookChangeKind.added,
          WorldbookChangeKind.modified,
        ]);
        expect(
          diff.entries.first.fieldDiffs.any((f) => f.key == 'content'),
          isTrue,
        );
        expect(diff.avatar!.hasChange, isTrue);
        expect(diff.changeCount, 2 + 2 + 1);
      },
    );

    test('removed entry is reported when missing from draft', () {
      final baseEntries = [entry(1, 'a'), entry(2, 'b')];
      final diff = computeCardDiff(
        baseCard: base(),
        baseEntries: baseEntries,
        draftCard: base(),
        draftEntries: [baseEntries.first],
      );
      expect(diff.entries.single.kind, WorldbookChangeKind.removed);
      expect(diff.entries.single.baseId, 2);
    });
  });

  group('buildCardSubmission', () {
    CharacterCard base() => const CharacterCard(
      name: 'A',
      description: 'old',
      tags: ['t1', 't2'],
      avatarHash: 'old-avatar',
      raw: {'spec': 'chara_card_v2'},
    );

    CharacterCard draftWith({
      String name = 'A',
      List<String> tags = const ['t1', 't2'],
      String? avatar = 'old-avatar',
    }) => CharacterCard(
      name: name,
      description: 'old',
      tags: tags,
      avatarHash: avatar,
      raw: const {'spec': 'chara_card_v2'},
    );

    WorldbookEntry entry(int id, String content, {String name = 'E'}) =>
        WorldbookEntry(
          id: id,
          characterId: 1,
          name: name,
          keys: const ['k'],
          content: content,
          position: id,
        );

    test(
      'default decisions accept the draft; full entry list is preserved',
      () {
        final baseEntries = [entry(1, 'keep'), entry(2, 'old')];
        final draftCard = draftWith(name: 'B', avatar: 'new-avatar');
        final draftEntries = [
          baseEntries.first,
          baseEntries[1].copyWith(content: 'new'),
          const WorldbookEntry(
            characterId: 1,
            id: -1,
            name: 'New',
            keys: ['n'],
            content: 'x',
          ),
        ];

        final submission = buildCardSubmission(
          baseCard: base(),
          baseEntries: baseEntries,
          draftCard: draftCard,
          draftEntries: draftEntries,
          decisions: ReviewDecisions.acceptAll,
        );

        expect(submission.card.name, 'B');
        expect(submission.card.raw, {'spec': 'chara_card_v2'});
        expect(submission.card.avatarHash, 'new-avatar');
        expect(submission.entries.map((e) => e.content), ['keep', 'new', 'x']);
      },
    );

    test('rejected field/entry decisions fall back to baseline', () {
      final baseEntries = [entry(1, 'old')];
      final draftCard = draftWith(name: 'B', tags: const ['z']);
      final draftEntries = [
        baseEntries.first.copyWith(content: 'new'),
        const WorldbookEntry(
          characterId: 1,
          id: -1,
          name: 'New',
          keys: ['n'],
          content: 'x',
        ),
      ];
      final decisions = ReviewDecisions.acceptAll
          .withField('name', const FieldDecision(accepted: false))
          .withField('tags', const FieldDecision(accepted: false))
          .withEntry('base:1', const EntryDecision(accepted: false))
          .withEntry('new:-1', const EntryDecision(accepted: false));

      final submission = buildCardSubmission(
        baseCard: base(),
        baseEntries: baseEntries,
        draftCard: draftCard,
        draftEntries: draftEntries,
        decisions: decisions,
      );

      expect(submission.card.name, 'A');
      expect(submission.card.tags, ['t1', 't2']);
      expect(submission.entries.single.content, 'old');
    });

    test('edited field text and edited entry are applied when accepted', () {
      final baseEntries = [entry(1, 'old')];
      final editedEntry = baseEntries.first.copyWith(
        content: 'manually edited',
      );
      final draftCard = draftWith(name: 'B');
      final decisions = ReviewDecisions.acceptAll
          .withField('name', const FieldDecision(editedText: 'Handwritten'))
          .withEntry('base:1', EntryDecision(editedEntry: editedEntry));
      final submission = buildCardSubmission(
        baseCard: base(),
        baseEntries: baseEntries,
        draftCard: draftCard,
        draftEntries: [baseEntries.first.copyWith(content: 'staged')],
        decisions: decisions,
      );
      expect(submission.card.name, 'Handwritten');
      expect(submission.entries.single.content, 'manually edited');
    });

    test('edited list fields keep elements containing newlines and commas', () {
      const baseCard = CharacterCard(
        name: 'A',
        alternateGreetings: ['old greeting'],
        tags: ['old,tag'],
      );
      const draftCard = CharacterCard(
        name: 'A',
        alternateGreetings: ['staged greeting'],
        tags: ['staged'],
      );
      final decisions = ReviewDecisions.acceptAll
          .withField(
            'alternateGreetings',
            const FieldDecision(editedList: ['line1\nline2', 'second']),
          )
          .withField('tags', const FieldDecision(editedList: ['a,b', 'c']));

      final submission = buildCardSubmission(
        baseCard: baseCard,
        baseEntries: const [],
        draftCard: draftCard,
        draftEntries: const [],
        decisions: decisions,
      );

      expect(submission.card.alternateGreetings, ['line1\nline2', 'second']);
      expect(submission.card.tags, ['a,b', 'c']);
    });

    test('rejected avatar keeps the baseline; accepted new avatar wins', () {
      final draftCard = draftWith(avatar: 'new-avatar');
      final rejected = buildCardSubmission(
        baseCard: base(),
        baseEntries: const [],
        draftCard: draftCard,
        draftEntries: const [],
        decisions: ReviewDecisions.acceptAll.withAvatar(false),
      );
      expect(rejected.card.avatarHash, 'old-avatar');

      final accepted = buildCardSubmission(
        baseCard: base(),
        baseEntries: const [],
        draftCard: draftCard,
        draftEntries: const [],
        decisions: ReviewDecisions.acceptAll,
      );
      expect(accepted.card.avatarHash, 'new-avatar');
    });

    test('validate re-checks AI-side caps for inline edits', () {
      final submission = CardSubmission(
        card: CharacterCard(
          name: 'A',
          description: 'x' * (kCardMaxDescriptionChars + 1),
          tags: List.generate(kCardMaxTags + 1, (i) => 't$i'),
        ),
        entries: [
          WorldbookEntry(
            characterId: 1,
            id: 1,
            name: 'E',
            keys: List.generate(kCardMaxEntryKeys + 1, (i) => 'k$i'),
            content: 'x' * (kCardMaxEntryContentChars + 1),
          ),
        ],
      );
      final errors = validateCardSubmission(submission);
      expect(errors.any((e) => e.contains('描述不能超过')), isTrue);
      expect(errors.any((e) => e.contains('标签不能超过')), isTrue);
      expect(errors.any((e) => e.contains('内容不能超过')), isTrue);
      expect(errors.any((e) => e.contains('关键词不能超过')), isTrue);
    });

    test('validate enforces entry count and worldbook text total', () {
      final tooMany = CardSubmission(
        card: const CharacterCard(name: 'A'),
        entries: [
          for (var i = 0; i < kCardMaxEntriesTotal + 1; i++)
            WorldbookEntry(
              characterId: 1,
              id: i + 1,
              name: 'E$i',
              keys: const ['k'],
              content: 'c',
            ),
        ],
      );
      expect(
        validateCardSubmission(
          tooMany,
        ).any((e) => e.contains('不能超过 $kCardMaxEntriesTotal 条')),
        isTrue,
      );

      final tooMuchText = CardSubmission(
        card: const CharacterCard(name: 'A'),
        entries: [
          for (
            var i = 0;
            i <= kCardMaxWorldbookTextChars ~/ kCardMaxEntryContentChars;
            i++
          )
            WorldbookEntry(
              characterId: 1,
              id: i + 1,
              name: 'E$i',
              keys: const ['k'],
              content: 'c' * kCardMaxEntryContentChars,
            ),
        ],
      );
      expect(
        validateCardSubmission(
          tooMuchText,
        ).any((e) => e.contains('世界书正文总量不能超过')),
        isTrue,
      );
    });

    test('valid submission passes the shared caps', () {
      final submission = buildCardSubmission(
        baseCard: const CharacterCard(name: 'A'),
        baseEntries: const [],
        draftCard: const CharacterCard(
          name: 'B',
          description: 'ok',
          tags: ['tag'],
          alternateGreetings: ['hello'],
        ),
        draftEntries: const [
          WorldbookEntry(
            characterId: 0,
            id: -1,
            name: 'New',
            keys: ['n'],
            content: 'x',
          ),
        ],
        decisions: ReviewDecisions.acceptAll,
      );
      expect(validateCardSubmission(submission), isEmpty);
    });

    test(
      'new entry with edited absence is dropped; validate catches empties',
      () {
        final submission = buildCardSubmission(
          baseCard: const CharacterCard(),
          baseEntries: const [],
          draftCard: const CharacterCard(name: ''),
          draftEntries: const [
            WorldbookEntry(characterId: 0, id: -1, name: 'Bad', content: ''),
          ],
          decisions: ReviewDecisions.acceptAll,
        );
        final errors = validateCardSubmission(submission);
        expect(errors, contains('角色名字不能为空'));
        expect(errors.any((e) => e.contains('内容不能为空')), isTrue);
        expect(errors.any((e) => e.contains('需要关键词或设为常驻')), isTrue);
      },
    );
  });

  group('entry diffs and effective decisions', () {
    test('all matching flags are reported, including whole words', () {
      final base = WorldbookEntry(
        id: 1,
        characterId: 1,
        name: 'E',
        keys: const ['k'],
        content: 'c',
      );
      final now = base.copyWith(caseSensitive: true, matchWholeWords: true);
      final diffs = entryFieldDiffs(base, now);
      expect(
        diffs.map((d) => d.key),
        containsAll(['caseSensitive', 'matchWholeWords']),
      );
      expect(entryEquals(base, now), isFalse);
      expect(entryEquals(base, base.copyWith()), isTrue);
    });

    test('effective field diff follows edited text and hides reverts', () {
      final field = FieldDiff(
        key: 'description',
        label: '描述',
        oldText: 'old',
        newText: 'agent',
        diff: diffText('old', 'agent'),
      );
      expect(
        effectiveFieldDiff(field, const FieldDecision()),
        same(field.diff),
      );
      expect(
        effectiveFieldDiff(field, const FieldDecision(editedText: 'old')),
        isNull,
      );
      final edited = effectiveFieldDiff(
        field,
        const FieldDecision(editedText: 'mine'),
      )!;
      expect(
        edited.lines.any(
          (l) => l.kind == DiffLineKind.added && l.text == 'mine',
        ),
        isTrue,
      );
    });

    test('effective entry diff uses the edited entry', () {
      final old = WorldbookEntry(
        id: 2,
        characterId: 1,
        name: 'E',
        keys: const ['k'],
        content: 'old',
      );
      final diff = WorldbookEntryDiff(
        kind: WorldbookChangeKind.modified,
        baseId: 2,
        oldEntry: old,
        newEntry: old.copyWith(content: 'agent'),
        fieldDiffs: entryFieldDiffs(old, old.copyWith(content: 'agent')),
      );
      final edited = old.copyWith(content: 'mine', background: true);
      final decision = EntryDecision(editedEntry: edited);
      expect(effectiveEntryValue(diff, decision), same(edited));
      final diffs = effectiveEntryFieldDiffs(diff, decision);
      expect(
        diffs.any((d) => d.key == 'content' && d.newText == 'mine'),
        isTrue,
      );
      expect(diffs.any((d) => d.key == 'background'), isTrue);
    });
  });
}
