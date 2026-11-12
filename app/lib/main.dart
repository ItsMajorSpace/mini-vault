import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' hide Column;

import 'sync.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  // A new file name: the pre-sync database (mini_vault.db) has plain tables where PowerSync wants views.
  final db = PowerSyncDatabase(
    schema: SqliteVaultStore.schema,
    path: '${dir.path}/vault.db',
  );
  await db.initialize();
  final auth = await openAuth(File('${dir.path}/session.json'));
  syncWhileSignedIn(auth, db);
  runApp(MiniVaultApp(auth: auth, db: db));
}

class MiniVaultApp extends StatelessWidget {
  const MiniVaultApp({super.key, required this.auth, required this.db});

  final GoTrueClient auth;
  final PowerSyncDatabase db;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mini Vault',
      home: StreamBuilder(
        stream: auth.onAuthStateChange,
        builder: (context, _) => auth.currentSession == null
            ? SignInScreen(auth: auth)
            : CollectionsScreen(
                vault: Vault(SqliteVaultStore(db)),
                db: db,
                onSignOut: auth.signOut,
              ),
      ),
    );
  }
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.auth});

  final GoTrueClient auth;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Signing in swaps this screen for the Collections through the auth state stream.
  Future<void> _submit({required bool signUp}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      final password = _password.text;
      final response = signUp
          ? await widget.auth.signUp(email: email, password: password)
          : await widget.auth.signInWithPassword(
              email: email,
              password: password,
            );
      if (response.session == null && mounted) {
        setState(() => _error = 'Check your email to confirm your account.');
      }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mini Vault')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _email,
            decoration: const InputDecoration(labelText: 'Email'),
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
          ),
          TextField(
            controller: _password,
            decoration: const InputDecoration(labelText: 'Password'),
            obscureText: true,
            autofillHints: const [AutofillHints.password],
          ),
          const SizedBox(height: 16),
          if (_error case final error?)
            Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : () => _submit(signUp: false),
            child: const Text('Sign in'),
          ),
          TextButton(
            onPressed: _busy ? null : () => _submit(signUp: true),
            child: const Text('Create account'),
          ),
        ],
      ),
    );
  }
}

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({
    super.key,
    required this.vault,
    required this.db,
    this.onSignOut,
  });

  final Vault vault;

  /// For the sync status only; Collections go through [vault].
  final PowerSyncDatabase db;
  final VoidCallback? onSignOut;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  late final _collections = widget.vault.watchCollections();

  Future<void> _create() async {
    final name = await _askName('New Collection', '');
    if (name == null) return;
    try {
      await widget.vault.createCollection(name);
    } on StateError {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your starter Workflow has not synced yet. Go online and try again.',
          ),
        ),
      );
    }
  }

  Future<void> _rename(Collection collection) async {
    final name = await _askName('Rename Collection', collection.name);
    if (name == null) return;
    await widget.vault.renameCollection(collection.id, name);
  }

  Future<String?> _askName(String title, String initial) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: title, initial: initial),
    );
    return (name == null || name.trim().isEmpty) ? null : name;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collections'),
        actions: [
          if (widget.onSignOut case final signOut?)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
              onPressed: signOut,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(32),
          child: SyncStatusBar(db: widget.db),
        ),
      ),
      body: StreamBuilder(
        stream: _collections,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not load Collections: ${snapshot.error}'),
            );
          }
          final collections = snapshot.data;
          if (collections == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (collections.isEmpty) {
            return const Center(child: Text('No Collections yet'));
          }
          return ListView(
            children: [
              for (final c in collections)
                ListTile(
                  title: Text(c.name),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CollectionScreen(
                        vault: widget.vault,
                        db: widget.db,
                        collection: c,
                      ),
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: 'Rename Collection',
                    onPressed: () => _rename(c),
                  ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: 'New Collection',
        child: const Icon(Icons.add),
      ),
    );
  }
}

/// A Collection's Units, grouped by Stage in Workflow order, with a model count per Stage.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({
    super.key,
    required this.vault,
    required this.db,
    required this.collection,
  });

  final Vault vault;

  /// For the sync status only; Units go through [vault].
  final PowerSyncDatabase db;
  final Collection collection;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late final _groups = widget.vault.watchStageGroups(widget.collection);

  Future<void> _add(List<Stage> stages) async {
    final result = await showDialog<_UnitFields>(
      context: context,
      builder: (_) => _UnitDialog(title: 'New Unit', stages: stages),
    );
    if (result == null) return;
    await widget.vault.addUnit(
      widget.collection,
      name: result.name,
      modelCount: result.modelCount,
      notes: result.notes,
      stageId: result.stageId!,
    );
  }

  Future<void> _edit(Unit unit) async {
    final result = await showDialog<_UnitFields>(
      context: context,
      builder: (_) => _UnitDialog(title: 'Edit Unit', unit: unit),
    );
    if (result == null) return;
    if (result.delete) return widget.vault.deleteUnit(unit.id);
    // Only changed fields, so edits to other fields on other devices are kept.
    await widget.vault.editUnit(
      unit.id,
      name: result.name == unit.name ? null : result.name,
      modelCount: result.modelCount == unit.modelCount
          ? null
          : result.modelCount,
      notes: result.notes == unit.notes ? null : result.notes,
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _groups,
      builder: (context, snapshot) {
        final groups = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.collection.name),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(32),
              child: SyncStatusBar(db: widget.db),
            ),
          ),
          body: switch (snapshot) {
            AsyncSnapshot(:final error?) => Center(
              child: Text('Could not load Units: $error'),
            ),
            _ when groups == null => const Center(
              child: CircularProgressIndicator(),
            ),
            _ => ListView(
              children: [
                for (final g in groups) ...[
                  ListTile(
                    title: Text(
                      g.stage.name,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    trailing: Text(
                      g.modelCount == 1 ? '1 model' : '${g.modelCount} models',
                    ),
                  ),
                  for (final u in g.units)
                    ListTile(
                      contentPadding: const EdgeInsets.only(
                        left: 32,
                        right: 16,
                      ),
                      title: Text(u.name),
                      subtitle: u.notes.isEmpty ? null : Text(u.notes),
                      trailing: Text('${u.modelCount}'),
                      onTap: () => _edit(u),
                    ),
                ],
              ],
            ),
          },
          floatingActionButton: groups == null
              ? null
              : FloatingActionButton(
                  onPressed: () => _add([for (final g in groups) g.stage]),
                  tooltip: 'New Unit',
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }
}

typedef _UnitFields = ({
  String name,
  int modelCount,
  String notes,
  String? stageId,
  bool delete,
});

/// Adds a Unit (with a starting Stage from [stages]) or edits [unit] (with a Delete button).
class _UnitDialog extends StatefulWidget {
  const _UnitDialog({required this.title, this.stages = const [], this.unit});

  final String title;
  final List<Stage> stages;
  final Unit? unit;

  @override
  State<_UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<_UnitDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.unit?.name);
  late final _count = TextEditingController(
    text: '${widget.unit?.modelCount ?? 1}',
  );
  late final _notes = TextEditingController(text: widget.unit?.notes);
  late String? _stageId = widget.stages.firstOrNull?.id;

  @override
  void dispose() {
    _name.dispose();
    _count.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _close({bool delete = false}) {
    if (!delete && !_form.currentState!.validate()) return;
    Navigator.pop<_UnitFields>(context, (
      name: _name.text.trim(),
      modelCount: int.tryParse(_count.text.trim()) ?? 0,
      notes: _notes.text.trim(),
      stageId: _stageId,
      delete: delete,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _form,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.unit == null,
                decoration: const InputDecoration(labelText: 'Name'),
                validator: (v) => v!.trim().isEmpty ? 'Enter a name' : null,
              ),
              TextFormField(
                controller: _count,
                decoration: const InputDecoration(labelText: 'Models'),
                keyboardType: TextInputType.number,
                validator: (v) =>
                    (int.tryParse(v!.trim()) ?? 0) < 1 ? 'At least 1' : null,
              ),
              TextFormField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: null,
              ),
              if (widget.stages.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _stageId,
                  decoration: const InputDecoration(labelText: 'Stage'),
                  items: [
                    for (final s in widget.stages)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (id) => _stageId = id,
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.unit != null)
          TextButton(
            onPressed: () => _close(delete: true),
            child: const Text('Delete'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: _close, child: const Text('Save')),
      ],
    );
  }
}

/// Shows whether local changes are still waiting to be uploaded, and whether the app is connected.
class SyncStatusBar extends StatefulWidget {
  const SyncStatusBar({super.key, required this.db});

  final PowerSyncDatabase db;

  @override
  State<SyncStatusBar> createState() => _SyncStatusBarState();
}

class _SyncStatusBarState extends State<SyncStatusBar> {
  late SyncStatus _status = widget.db.currentStatus;
  int _waiting = 0;
  late final List<StreamSubscription<void>> _subscriptions;

  @override
  void initState() {
    super.initState();
    _subscriptions = [
      widget.db.statusStream.listen((s) => setState(() => _status = s)),
      // ps_crud is PowerSync's upload queue: local writes add to it, finished uploads remove from it.
      widget.db
          .watch(
            'SELECT count(*) AS n FROM ps_crud',
            triggerOnTables: const ['ps_crud'],
          )
          .listen((rows) => setState(() => _waiting = rows.first['n'] as int)),
    ];
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch ((_waiting, _status.connected)) {
      (0, true) => (Icons.cloud_done, 'All changes synced'),
      (0, false) => (Icons.cloud_off, 'Offline'),
      (1, _) => (Icons.cloud_upload, '1 change waiting to sync'),
      (final n, _) => (Icons.cloud_upload, '$n changes waiting to sync'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [Icon(icon, size: 16), const SizedBox(width: 8), Text(text)],
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.initial});

  final String title;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    void save() => Navigator.pop(context, _controller.text);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Name'),
        onSubmitted: (_) => save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(onPressed: save, child: const Text('Save')),
      ],
    );
  }
}
