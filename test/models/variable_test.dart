import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/models/variable.dart';

void main() {
  test('toMap/fromMap round-trips', () {
    const v = Variable(id: 9, sessionId: 4, key: 'hp', value: '10');
    final r = Variable.fromMap(v.toMap());
    expect(r.id, 9);
    expect(r.sessionId, 4);
    expect(r.key, 'hp');
    expect(r.value, '10');
    // 缺省是最保守的 protected,与人工新增/导入默认一致。
    expect(r.agentAccess, VariableAccess.protected);
  });

  test('agent access round-trips and unknown storage falls back to protected', () {
    for (final access in VariableAccess.values) {
      final row = Variable(
        id: 1,
        sessionId: 1,
        key: 'hp',
        value: '10',
        agentAccess: access,
      ).toMap();
      expect(row['agent_access'], access.name);
      expect(Variable.fromMap(row).agentAccess, access);
    }
    expect(VariableAccess.fromStorage('unknown'), VariableAccess.protected);
    expect(VariableAccess.fromStorage(null), VariableAccess.protected);
  });

  test('trash and proposal rows decode timestamps', () {
    final trash = VariableTrashEntry.fromMap({
      'id': 2,
      'session_id': 4,
      'key': 'location',
      'value': 'cave',
      'agent_access': 'full',
      'deleted_at': 1700000000000,
      'deleted_by': 'agent',
    });
    expect(trash.byAgent, isTrue);
    expect(trash.deletedAt, DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(trash.agentAccess, VariableAccess.full);

    final proposal = VariableDeletionProposal.fromMap({
      'id': 3,
      'session_id': 4,
      'key': 'weather',
      'value': 'rain',
      'created_at': 1700000001000,
    });
    expect(proposal.key, 'weather');
    expect(proposal.createdAt, DateTime.fromMillisecondsSinceEpoch(1700000001000));
  });
}
