import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/account.dart';

void main() {
  testWidgets('account deletion is confirmed only by retyping the email', (
    tester,
  ) async {
    bool? confirmed;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => confirmed = await showDialog<bool>(
              context: context,
              builder: (_) =>
                  const DeleteAccountDialog(email: 'Collector@example.com'),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    Finder delete() => find.widgetWithText(TextButton, 'Delete account');
    bool enabled() => tester.widget<TextButton>(delete()).onPressed != null;

    expect(enabled(), isFalse);
    await tester.enterText(find.byType(TextField), 'collector@example.co');
    await tester.pump();
    expect(enabled(), isFalse);
    await tester.enterText(find.byType(TextField), ' collector@example.com ');
    await tester.pump();
    expect(enabled(), isTrue);

    await tester.tap(delete());
    await tester.pumpAndSettle();
    expect(confirmed, isTrue);
  });
}
