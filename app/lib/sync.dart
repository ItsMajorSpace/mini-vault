/// Accounts (GoTrue) and sync (PowerSync plus the write API), as set up in server/docker-compose.yaml.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gotrue/gotrue.dart';
import 'package:http/http.dart' as http;
import 'package:powersync/powersync.dart';

// Defaults reach the local stack from the Android emulator; override with --dart-define.
const authUrl = String.fromEnvironment(
  'AUTH_URL',
  defaultValue: 'http://10.0.2.2:9999',
);
const powerSyncUrl = String.fromEnvironment(
  'POWERSYNC_URL',
  defaultValue: 'http://10.0.2.2:8080',
);
const apiUrl = String.fromEnvironment(
  'API_URL',
  defaultValue: 'http://10.0.2.2:8000',
);

/// A GoTrue client whose session is kept in [sessionFile], so the user stays signed in across launches.
/// Restoring needs no network: an expired access token is refreshed once online.
Future<GoTrueClient> openAuth(File sessionFile) async {
  final auth = GoTrueClient(url: authUrl, flowType: AuthFlowType.implicit);
  if (await sessionFile.exists()) {
    await auth.setInitialSession(await sessionFile.readAsString());
  }
  auth.onAuthStateChange.listen((state) async {
    if (state.session case final session?) {
      await sessionFile.writeAsString(jsonEncode(session.toJson()));
    } else if (await sessionFile.exists()) {
      await sessionFile.delete();
    }
  });
  return auth;
}

/// Syncs while signed in. Signing out clears the local database, so the next account starts empty.
void syncWhileSignedIn(GoTrueClient auth, PowerSyncDatabase db) {
  auth.onAuthStateChange.listen((state) async {
    switch (state.event) {
      case AuthChangeEvent.initialSession || AuthChangeEvent.signedIn
          when state.session != null:
        // A new connector each time: a connector caches its credentials, which would sync the previous account.
        await db.connect(connector: _ServerConnector(auth));
      case AuthChangeEvent.signedOut:
        await db.disconnectAndClear();
      default:
    }
  });
}

class _ServerConnector extends PowerSyncBackendConnector {
  _ServerConnector(this._auth);

  final GoTrueClient _auth;

  @override
  Future<PowerSyncCredentials?> fetchCredentials() async {
    final session = await _auth.getSession();
    if (session == null) return null;
    return PowerSyncCredentials(
      endpoint: powerSyncUrl,
      token: session.accessToken,
      userId: session.user.id,
    );
  }

  /// Sends one local transaction to the write API. Throwing makes PowerSync retry later (offline, server down);
  /// a rejected transaction (another user's row, invalid data) is dropped, and the next sync restores the server's rows.
  @override
  Future<void> uploadData(PowerSyncDatabase database) async {
    final transaction = await database.getNextCrudTransaction();
    if (transaction == null) return;
    final session = await _auth.getSession();
    if (session == null) throw StateError('Signed out');

    final response = await http.post(
      Uri.parse('$apiUrl/upload'),
      headers: {
        'authorization': 'Bearer ${session.accessToken}',
        'content-type': 'application/json',
      },
      body: jsonEncode({
        'operations': [for (final op in transaction.crud) op.toJson()],
      }),
    );
    if (response.statusCode == 401) {
      invalidateCredentials();
      throw http.ClientException(
        'Upload unauthorized, retrying with a fresh token',
      );
    }
    if (response.statusCode >= 500) {
      throw http.ClientException('Upload failed: ${response.statusCode}');
    }
    if (response.statusCode >= 400) {
      debugPrint('Upload rejected, dropping it: ${response.body}');
    }
    await transaction.complete();
  }
}
