// 后台记忆提议卡:只读展示 + 采用/忽略两个显式动作。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:microscritt/ui/status/status_widgets.dart';

void main() {
  testWidgets('memory proposal card renders the proposal and fires both actions', (tester) async {
    var accepted = 0;
    var dismissed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MemoryProposalCard(
            proposal: 'new memory facts',
            enabled: true,
            onAccept: () => accepted++,
            onDismiss: () => dismissed++,
          ),
        ),
      ),
    );

    expect(find.text('后台记忆建议'), findsOneWidget);
    expect(find.text('new memory facts'), findsOneWidget);
    expect(find.text('采用建议'), findsOneWidget);

    await tester.tap(find.text('采用建议'));
    await tester.tap(find.byTooltip('忽略建议'));
    expect(accepted, 1);
    expect(dismissed, 1);
  });
}
