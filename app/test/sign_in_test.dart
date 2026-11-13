import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';

void main() {
  testWidgets('the password field shows and hides the password', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SignInScreen(
          auth: GoTrueClient(url: 'http://localhost', autoRefreshToken: false),
        ),
      ),
    );
    final password = find.widgetWithText(TextField, 'Password');
    bool obscured() => tester.widget<TextField>(password).obscureText;

    await tester.enterText(password, 'hunter2');
    expect(obscured(), isTrue);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(obscured(), isFalse);
    expect(find.text('hunter2'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide password'));
    await tester.pump();
    expect(obscured(), isTrue);
  });
}
