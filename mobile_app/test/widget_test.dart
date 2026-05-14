import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/main.dart';

void main() {
  testWidgets('renders control console', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexMobileControlApp());

    expect(find.text('Codex 手机控制台'), findsOneWidget);
    expect(find.text('Backend WebSocket'), findsOneWidget);
    expect(find.text('给电脑上的 Codex 发指令'), findsOneWidget);
  });
}
