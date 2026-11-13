import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' hide Column;

import 'photos.dart';
import 'progress.dart';
import 'sync.dart';
import 'workflows.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  // A new file name: the pre-sync database (mini_vault.db) has plain tables where PowerSync wants views.
  final db = PowerSyncDatabase(
    schema: Schema([...SqliteVaultStore.schema.tables, photoQueueTable]),
    path: '${dir.path}/vault.db',
  );
  await db.initialize();
  final auth = await openAuth(File('${dir.path}/session.json'));
  final photos = PhotoFiles(db, auth, Directory('${dir.path}/photos'));
  syncWhileSignedIn(auth, db, photos.queue);
  runApp(MiniVaultApp(auth: auth, db: db, photos: photos));
}

class MiniVaultApp extends StatelessWidget {
  const MiniVaultApp({
    super.key,
    required this.auth,
    required this.db,
    required this.photos,
  });

  final GoTrueClient auth;
  final PowerSyncDatabase db;
  final PhotoFiles photos;

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
                photos: photos,
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
    this.photos,
    this.onSignOut,
  });

  final Vault vault;

  /// For the sync status only; Collections go through [vault].
  final PowerSyncDatabase db;

  /// Null hides Units' photos.
  final PhotoFiles? photos;
  final VoidCallback? onSignOut;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  late final _collections = widget.vault.watchCollections();

  Future<void> _create() async {
    final workflows = await widget.vault.workflows();
    if (!mounted) return;
    if (workflows.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Your starter Workflow has not synced yet. Go online and try again.',
          ),
        ),
      );
      return;
    }
    final picked = await showDialog<(String, String)>(
      context: context,
      builder: (_) => NewCollectionDialog(workflows: workflows),
    );
    if (picked case (final name, final workflowId) when mounted) {
      await attempt(
        context,
        () => widget.vault.createCollection(name, workflowId: workflowId),
      );
    }
  }

  Future<void> _rename(Collection collection) async {
    final name = await askName(context, 'Rename Collection', collection.name);
    if (name == null) return;
    await widget.vault.renameCollection(collection.id, name);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Collections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.account_tree),
            tooltip: 'Workflows',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => WorkflowsScreen(vault: widget.vault),
              ),
            ),
          ),
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
                  key: ValueKey(c.id),
                  title: Text(c.name),
                  subtitle: ProgressSummary(vault: widget.vault, collection: c),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => CollectionScreen(
                        vault: widget.vault,
                        db: widget.db,
                        photos: widget.photos,
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
    this.photos,
    required this.collection,
  });

  final Vault vault;

  /// For the sync status only; Units go through [vault].
  final PowerSyncDatabase db;
  final PhotoFiles? photos;
  final Collection collection;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  late final _groups = widget.vault.watchStageGroups(widget.collection);

  Future<void> _add(List<Stage> stages) async {
    final result = await showDialog<_UnitFields>(
      context: context,
      builder: (_) => _UnitDialog(
        title: 'New Unit',
        stages: stages,
        suggestTags: widget.vault.suggestTags,
      ),
    );
    if (result == null) return;
    final unit = await widget.vault.addUnit(
      widget.collection,
      name: result.name,
      modelCount: result.modelCount,
      notes: result.notes,
      stageId: result.stageId!,
    );
    await widget.vault.addTags(unit.id, result.tags);
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
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: ProgressSummary(
                    vault: widget.vault,
                    collection: widget.collection,
                  ),
                ),
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
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => UnitScreen(
                            vault: widget.vault,
                            photos: widget.photos,
                            collection: widget.collection,
                            unitId: u.id,
                          ),
                        ),
                      ),
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

/// A Unit's fields, its photos, its Stage (with a Move action) and its history of Stage Changes.
class UnitScreen extends StatefulWidget {
  const UnitScreen({
    super.key,
    required this.vault,
    this.photos,
    required this.collection,
    required this.unitId,
  });

  final Vault vault;
  final PhotoFiles? photos;
  final Collection collection;
  final String unitId;

  @override
  State<UnitScreen> createState() => _UnitScreenState();
}

class _UnitScreenState extends State<UnitScreen> {
  // The Stage groups carry both the Workflow's Stages and the Unit's current fields.
  late final _groups = widget.vault.watchStageGroups(widget.collection);
  late final _history = widget.vault.watchHistory(widget.unitId);

  Future<void> _edit(Unit unit) async {
    final tags = await widget.vault.tagsOf(unit.id);
    if (!mounted) return;
    final result = await showDialog<_UnitFields>(
      context: context,
      builder: (_) => _UnitDialog(
        title: 'Edit Unit',
        unit: unit,
        tags: tags,
        suggestTags: widget.vault.suggestTags,
      ),
    );
    if (result == null) return;
    if (result.delete) {
      await widget.vault.deleteUnit(unit.id);
      if (mounted) Navigator.pop(context);
      return;
    }
    final kept = {for (final t in result.tags) tagKey(t)};
    for (final t in tags.where((t) => !kept.contains(tagKey(t)))) {
      await widget.vault.removeTag(unit.id, t);
    }
    await widget.vault.addTags(unit.id, result.tags);
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

  Future<void> _move(Unit unit, List<Stage> stages) async {
    final stageId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move to Stage'),
        children: [
          for (final s in stages)
            ListTile(
              leading: Icon(
                s.id == unit.stageId ? Icons.check : null,
                semanticLabel: s.id == unit.stageId ? 'Current Stage' : null,
              ),
              title: Text(s.name),
              onTap: () => Navigator.pop(context, s.id),
            ),
        ],
      ),
    );
    if (stageId != null && mounted) {
      await attempt(context, () => widget.vault.moveUnit(unit, stageId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _groups,
      builder: (context, snapshot) {
        final groups = snapshot.data ?? const [];
        final stages = [for (final g in groups) g.stage];
        final unit = groups
            .expand((g) => g.units)
            .where((u) => u.id == widget.unitId)
            .firstOrNull;
        String stageName(String? id) =>
            stages.where((s) => s.id == id).firstOrNull?.name ??
            'a deleted Stage';
        final localizations = MaterialLocalizations.of(context);
        return Scaffold(
          appBar: AppBar(
            title: Text(unit?.name ?? ''),
            actions: [
              if (unit != null)
                IconButton(
                  icon: const Icon(Icons.edit),
                  tooltip: 'Edit Unit',
                  onPressed: () => _edit(unit),
                ),
            ],
          ),
          body: switch (snapshot) {
            AsyncSnapshot(:final error?) => Center(
              child: Text('Could not load the Unit: $error'),
            ),
            _ when unit == null => const Center(
              child: CircularProgressIndicator(),
            ),
            _ => ListView(
              children: [
                if (widget.photos case final photos?)
                  UnitPhotos(
                    vault: widget.vault,
                    files: photos,
                    unitId: unit.id,
                  ),
                ListTile(
                  title: Text(stageName(unit.stageId)),
                  subtitle: Text(
                    unit.modelCount == 1
                        ? '1 model'
                        : '${unit.modelCount} models',
                  ),
                  trailing: FilledButton(
                    onPressed: () => _move(unit, stages),
                    child: const Text('Move'),
                  ),
                ),
                if (unit.notes.isNotEmpty) ListTile(title: Text(unit.notes)),
                ListTile(
                  title: Text(
                    'History',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                StreamBuilder(
                  stream: _history,
                  builder: (context, history) => Column(
                    children: [
                      for (final c in (history.data ?? const []).reversed)
                        ListTile(
                          title: Text(
                            c.fromStageId == null
                                ? 'Added at ${stageName(c.toStageId)}'
                                : '${stageName(c.fromStageId)} → ${stageName(c.toStageId)}',
                          ),
                          subtitle: Text(
                            '${localizations.formatMediumDate(c.happenedAt.toLocal())} '
                            '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(c.happenedAt.toLocal()))}',
                          ),
                          trailing: Text('${c.modelCount}'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          },
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
  List<String> tags,
  bool delete,
});

/// Adds a Unit (with a starting Stage from [stages]) or edits [unit] (with a Delete button).
class _UnitDialog extends StatefulWidget {
  const _UnitDialog({
    required this.title,
    this.stages = const [],
    this.unit,
    this.tags = const [],
    required this.suggestTags,
  });

  final String title;
  final List<Stage> stages;
  final Unit? unit;
  final List<String> tags;
  final Future<List<String>> Function(String prefix) suggestTags;

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
  late final _tags = [...widget.tags];
  final _tag = TextEditingController();
  final _tagFocus = FocusNode();

  void _addTag(String name) {
    final key = tagKey(name);
    if (key.isNotEmpty && !_tags.any((t) => tagKey(t) == key)) {
      setState(() => _tags.add(name.trim()));
    }
    _tag.clear();
  }

  @override
  void dispose() {
    _name.dispose();
    _count.dispose();
    _notes.dispose();
    _tag.dispose();
    _tagFocus.dispose();
    super.dispose();
  }

  void _close({bool delete = false}) {
    if (!delete && !_form.currentState!.validate()) return;
    _addTag(_tag.text); // A Tag typed but not yet submitted.
    Navigator.pop<_UnitFields>(context, (
      name: _name.text.trim(),
      modelCount: int.tryParse(_count.text.trim()) ?? 0,
      notes: _notes.text.trim(),
      stageId: _stageId,
      tags: _tags,
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
              Autocomplete<String>(
                textEditingController: _tag,
                focusNode: _tagFocus,
                optionsBuilder: (value) async => [
                  for (final t in await widget.suggestTags(value.text))
                    if (!_tags.any((added) => tagKey(added) == tagKey(t))) t,
                ],
                fieldViewBuilder: (context, field, focus, submit) =>
                    TextFormField(
                      controller: field,
                      focusNode: focus,
                      decoration: const InputDecoration(labelText: 'Add Tag'),
                      onFieldSubmitted: (v) {
                        _addTag(v);
                        focus.requestFocus(); // Ready for the next Tag.
                      },
                    ),
                onSelected: _addTag,
              ),
              Wrap(
                spacing: 8,
                children: [
                  for (final t in _tags)
                    InputChip(
                      label: Text(t),
                      onDeleted: () => setState(() => _tags.remove(t)),
                      deleteButtonTooltipMessage: 'Remove Tag $t',
                    ),
                ],
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
