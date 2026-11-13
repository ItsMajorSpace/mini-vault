/// Password reset and account deletion. Signing out is in the Collections screen's account menu.
library;

import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';

import 'sync.dart';
import 'theme.dart';

/// Resets a forgotten password: GoTrue emails a code, which the user types in here with a new password.
/// A code rather than a link, so the app needs no deep links. Using the code signs in.
class ResetPasswordScreen extends StatefulWidget {
  const ResetPasswordScreen({super.key, required this.auth, this.email = ''});

  final GoTrueClient auth;
  final String email;

  @override
  State<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends State<ResetPasswordScreen> {
  late final _email = TextEditingController(text: widget.email);
  final _code = TextEditingController();
  final _password = TextEditingController();
  bool _sent = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AuthException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on Exception {
      if (mounted) {
        setState(() => _error = 'Could not reach the server. Are you online?');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() => _run(() async {
    await widget.auth.resetPasswordForEmail(_email.text.trim());
    if (mounted) setState(() => _sent = true);
  });

  Future<void> _reset() => _run(() async {
    // Already signed in if the code worked but the new password was refused: a code works only once.
    if (widget.auth.currentSession == null) {
      await widget.auth.verifyOTP(
        type: OtpType.recovery,
        email: _email.text.trim(),
        token: _code.text.trim(),
      );
    }
    await widget.auth.updateUser(UserAttributes(password: _password.text));
    if (mounted) Navigator.pop(context);
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _email,
            enabled: !_sent,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
          ),
          if (_sent) ...[
            const SizedBox(height: 16),
            const Text('We emailed you a code. Enter it with a new password.'),
            TextField(
              controller: _code,
              decoration: const InputDecoration(labelText: 'Code'),
              keyboardType: TextInputType.number,
              autofillHints: const [AutofillHints.oneTimeCode],
            ),
            TextField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'New password'),
              obscureText: true,
              autofillHints: const [AutofillHints.newPassword],
            ),
          ],
          const SizedBox(height: 16),
          if (_error case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          if (_sent)
            FilledButton(
              onPressed: _busy ? null : _reset,
              child: const Text('Set new password'),
            )
          else
            FilledButton(
              onPressed: _busy ? null : _send,
              child: const Text('Email me a code'),
            ),
        ],
      ),
    );
  }
}

/// Asks the user to confirm by retyping their email, then deletes their account on the server and signs out,
/// which clears this device.
Future<void> deleteAccount(BuildContext context, GoTrueClient auth) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => DeleteAccountDialog(email: auth.currentUser?.email ?? ''),
  );
  if (confirmed != true) return;
  try {
    await deleteAccountOnServer(auth);
  } on Exception {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not delete your account. Are you online?'),
        ),
      );
    }
    return;
  }
  try {
    await auth.signOut();
  } on Exception {
    // The session is already cleared locally; telling GoTrue fails for the deleted user.
  }
}

/// Answers true once the user has retyped [email] and pressed Delete.
class DeleteAccountDialog extends StatefulWidget {
  const DeleteAccountDialog({super.key, required this.email});

  final String email;

  @override
  State<DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<DeleteAccountDialog> {
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches =
        _typed.text.trim().toLowerCase() == widget.email.toLowerCase();
    return AlertDialog(
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'All your Collections, Units, Workflows, history and photos will be deleted '
            'on all your devices. This cannot be undone.',
          ),
          TextField(
            controller: _typed,
            decoration: InputDecoration(labelText: 'Type ${widget.email}'),
            keyboardType: TextInputType.emailAddress,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: matches && widget.email.isNotEmpty
              ? () => Navigator.pop(context, true)
              : null,
          style: destructive(context),
          child: const Text('Delete account'),
        ),
      ],
    );
  }
}
