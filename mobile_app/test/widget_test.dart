import 'package:flutter_test/flutter_test.dart';

import 'package:mobile_app/main.dart';

void main() {
  testWidgets('renders device-first flow', (WidgetTester tester) async {
    await tester.pumpWidget(const CodexMobileControlApp(autoConnect: false));

    expect(find.text('选择设备'), findsOneWidget);
    expect(find.text('服务器未连接'), findsOneWidget);
    expect(find.text('离线'), findsOneWidget);
    expect(find.text('--'), findsOneWidget);
  });
}
