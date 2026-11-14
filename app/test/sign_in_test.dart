import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mini_vault/main.dart';

/// A GoTrue server faked at the HTTP layer: [respond] answers each request, which [requests] records.
class FakeServer {
  FakeServer(this.respond);

  Future<http.Response> Function(http.Request request) respond;
  final requests = <http.Request>[];

  GoTrueClient get auth => GoTrueClient(
    url: 'http://localhost',
    autoRefreshToken: false,
    flowType: AuthFlowType.implicit, // as openAuth
    httpClient: MockClient((request) {
      requests.add(request);
      return respond(request);
    }),
  );
}

http.Response json(int status, Map<String, Object?> body) =>
    http.Response(jsonEncode(body), status);

final invalidCredentials = json(400, {
  'code': 400,
  'error_code': 'invalid_credentials',
  'msg': 'Invalid login credentials',
});

/// A new user awaiting email confirmation: no session.
final unconfirmedUser = json(200, {
  'id': 'u1',
  'aud': 'authenticated',
  'email': 'ash@example.com',
  'app_metadata': <String, Object?>{},
  'user_metadata': <String, Object?>{},
  'created_at': '2026-11-14T00:00:00Z',
});

Future<FakeServer> pumpSignIn(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) respond,
) async {
  final server = FakeServer(respond);
  await tester.pumpWidget(MaterialApp(home: SignInScreen(auth: server.auth)));
  return server;
}

Finder field(String label) => find.widgetWithText(TextField, label);
Finder button(String label) => find.widgetWithText(FilledButton, label);
final segments = find.byWidgetPredicate((w) => w is SegmentedButton);
Future<void> mode(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: segments, matching: find.text(label)));
  await tester.pumpAndSettle();
}

Future<void> fill(WidgetTester tester) async {
  await tester.enterText(field('Email'), 'ash@example.com');
  await tester.enterText(field('Password'), 'hunter22');
}

void main() {
  testWidgets('the password field shows and hides the password', (
    tester,
  ) async {
    await pumpSignIn(tester, (_) async => invalidCredentials);
    final password = field('Password');
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

  testWidgets('shows the wordmark and tagline, no AppBar', (tester) async {
    await pumpSignIn(tester, (_) async => invalidCredentials);
    expect(find.text('MINI VAULT'), findsOneWidget);
    expect(
      find.text('Every model, from wishlist to finished.'),
      findsOneWidget,
    );
    expect(find.byType(AppBar), findsNothing);
  });

  testWidgets('switching modes changes the button and links, keeping typed '
      'text', (tester) async {
    await pumpSignIn(tester, (_) async => invalidCredentials);
    const confirmLine =
        "You'll get an email to confirm your account before you can sign in.";
    await fill(tester);
    expect(button('Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text(confirmLine), findsNothing);

    await mode(tester, 'Create account');
    expect(button('Create account'), findsOneWidget);
    expect(button('Sign in'), findsNothing);
    expect(find.text('Forgot password?'), findsNothing);
    expect(find.text(confirmLine), findsOneWidget);
    expect(tester.widget<TextField>(field('Password')).autofillHints, [
      AutofillHints.newPassword,
    ]);
    expect(find.text('ash@example.com'), findsOneWidget);

    await mode(tester, 'Sign in');
    expect(button('Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text(confirmLine), findsNothing);
    expect(find.text('ash@example.com'), findsOneWidget);
  });

  testWidgets('Sign in signs in with the password', (tester) async {
    final server = await pumpSignIn(tester, (_) async => invalidCredentials);
    await fill(tester);
    await tester.tap(button('Sign in'));
    await tester.pumpAndSettle();
    expect(server.requests.single.url.path, '/token');
    expect(
      server.requests.single.url.queryParameters['grant_type'],
      'password',
    );
    expect(
      jsonDecode(server.requests.single.body),
      allOf(
        containsPair('email', 'ash@example.com'),
        containsPair('password', 'hunter22'),
      ),
    );
  });

  testWidgets('Create account signs up', (tester) async {
    final server = await pumpSignIn(tester, (_) async => unconfirmedUser);
    await fill(tester);
    await mode(tester, 'Create account');
    await tester.tap(button('Create account'));
    await tester.pumpAndSettle();
    expect(server.requests.single.url.path, '/signup');
    expect(
      jsonDecode(server.requests.single.body),
      containsPair('email', 'ash@example.com'),
    );
  });

  for (final (modeLabel, busyLabel) in [
    ('Sign in', 'Signing in…'),
    ('Create account', 'Creating account…'),
  ]) {
    testWidgets('while busy ($modeLabel) inputs are disabled and the button '
        'reads $busyLabel', (tester) async {
      final reply = Completer<http.Response>();
      await pumpSignIn(tester, (_) => reply.future);
      await fill(tester);
      await mode(tester, modeLabel);
      await tester.tap(button(modeLabel));
      await tester.pump();

      expect(find.text(busyLabel), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(field('Email')).enabled, isFalse);
      expect(tester.widget<TextField>(field('Password')).enabled, isFalse);
      expect(
        tester.widget<SegmentedButton>(segments).onSelectionChanged,
        isNull,
      );
      if (modeLabel == 'Sign in') {
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Forgot password?'),
              )
              .onPressed,
          isNull,
        );
      }

      reply.complete(invalidCredentials);
      await tester.pumpAndSettle();
      expect(button(modeLabel), findsOneWidget);
      expect(tester.widget<TextField>(field('Email')).enabled, isTrue);
    });
  }

  testWidgets('offline shows the cloud notice and Try again, cleared on '
      'edit', (tester) async {
    final server = await pumpSignIn(
      tester,
      (_) async => throw http.ClientException('Failed host lookup'),
    );
    await fill(tester);
    await tester.tap(button('Sign in'));
    await tester.pumpAndSettle();

    final notice = find.byType(AuthNotice);
    expect(notice, findsOneWidget);
    expect(
      find.descendant(of: notice, matching: find.byIcon(Icons.cloud_off)),
      findsOneWidget,
    );
    expect(find.text('Could not reach the server.'), findsOneWidget);
    expect(find.text('Are you online?'), findsOneWidget);
    expect(button('Try again'), findsOneWidget);

    await tester.tap(button('Try again'));
    await tester.pumpAndSettle();
    expect(server.requests, hasLength(2));
    expect(server.requests.last.url.path, '/token');

    await tester.enterText(field('Password'), 'hunter23');
    await tester.pump();
    expect(notice, findsNothing);
    expect(button('Sign in'), findsOneWidget);
  });

  testWidgets('an auth error shows its message alone, cleared on mode '
      'change', (tester) async {
    await pumpSignIn(tester, (_) async => invalidCredentials);
    await fill(tester);
    await tester.tap(button('Sign in'));
    await tester.pumpAndSettle();

    final notice = find.byType(AuthNotice);
    expect(
      find.descendant(of: notice, matching: find.byIcon(Icons.error)),
      findsOneWidget,
    );
    expect(
      tester.widget<AuthNotice>(notice).title,
      'Invalid login credentials',
    );
    expect(tester.widget<AuthNotice>(notice).detail, isNull);
    expect(button('Sign in'), findsOneWidget);

    await mode(tester, 'Create account');
    expect(notice, findsNothing);
  });

  testWidgets('sign-up without a session shows Check your email; Back to sign '
      'in keeps the email', (tester) async {
    await pumpSignIn(tester, (_) async => unconfirmedUser);
    await fill(tester);
    await mode(tester, 'Create account');
    await tester.tap(button('Create account'));
    await tester.pumpAndSettle();

    expect(find.text('Check your email'), findsOneWidget);
    expect(find.byIcon(Icons.mark_email_unread), findsOneWidget);
    expect(
      find.textContaining(
        'We sent a link to ash@example.com',
        findRichText: true,
      ),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsNothing);

    await tester.tap(button('Back to sign in'));
    await tester.pumpAndSettle();
    expect(button('Sign in'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(find.text('ash@example.com'), findsOneWidget);
  });
}
