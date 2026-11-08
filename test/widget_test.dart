import 'package:flutter_test/flutter_test.dart';
import 'package:termux_ssh_bridge/main.dart';

void main() {
  testWidgets('TermuxSshBridgeApp smoke test - Iteration 1', (WidgetTester tester) async {
    await tester.pumpWidget(const TermuxSshBridgeApp());
    expect(find.text('Termux SSH Bridge'), findsOneWidget);
  });

  testWidgets('TermuxSshBridgeApp smoke test - Iteration 2', (WidgetTester tester) async {
    await tester.pumpWidget(const TermuxSshBridgeApp());
    expect(find.text('Termux SSH Bridge'), findsOneWidget);
  });

  testWidgets('TermuxSshBridgeApp smoke test - Iteration 3', (WidgetTester tester) async {
    await tester.pumpWidget(const TermuxSshBridgeApp());
    expect(find.text('Termux SSH Bridge'), findsOneWidget);
  });
}
