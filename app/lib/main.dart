import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' hide Column;

import 'account.dart';
import 'photos.dart';
import 'progress.dart';
import 'squad.dart';
import 'sync.dart';
import 'theme.dart';
import 'workflows.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  // A new file name: the pre-sync database (mini_vault.db) has plain tables where PowerSync wants views.
  final db = PowerSyncDatabase(schema: appSchema, path: '${dir.path}/vault.db');
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
      theme: grimdarkTheme,
      home: StreamBuilder(
        stream: auth.onAuthStateChange,
        builder: (context, _) => auth.currentSession == null
            ? SignInScreen(auth: auth)
            : CollectionsScreen(
                vault: Vault(SqliteVaultStore(db)),
                db: db,
                photos: photos,
                email: auth.currentUser?.email,
                onSignOut: auth.signOut,
                onSyncNow: () => syncNow(auth, db, photos.queue),
                onDeleteAccount: () => deleteAccount(context, auth),
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
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => ResetPasswordScreen(
                        auth: widget.auth,
                        email: _email.text.trim(),
                      ),
                    ),
                  ),
            child: const Text('Forgot password?'),
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
    this.email,
    this.onSignOut,
    this.onDeleteAccount,
    this.onSyncNow,
  });

  final Vault vault;

  /// For the sync status only; Collections go through [vault].
  final PowerSyncDatabase db;

  /// Null hides Units' photos.
  final PhotoFiles? photos;

  /// The signed-in user's, shown atop the account menu.
  final String? email;

  /// Null hides Sign out and Delete account.
  final VoidCallback? onSignOut;
  final VoidCallback? onDeleteAccount;

  /// Null hides Sync now.
  final Future<void> Function()? onSyncNow;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  late final _collections = widget.vault.watchCollections();
  late final _progress = widget.vault.watchProgressByWorkflow();
  late final _recent = widget.vault.watchRecentlyMoved();
  // Kept up to date rather than read on tap, so signing out can warn without waiting on SQLite.
  int _unsynced = 0;
  late final StreamSubscription<int> _unsyncedSubscription;

  @override
  void initState() {
    super.initState();
    _unsyncedSubscription = watchUnsynced(widget.db)
        .listen((n) => setState(() => _unsynced = n));
  }

  @override
  void dispose() {
    _unsyncedSubscription.cancel();
    super.dispose();
  }

  /// Signing out clears this device, so with changes not synced yet it asks first.
  Future<void> _signOut(VoidCallback signOut) async {
    final n = _unsynced;
    if (n > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Sign out with unsynced changes?'),
          content: Text(
            '${n == 1 ? "1 change hasn't" : "$n changes haven't"} synced yet and will be lost. '
            'Connect to the internet and wait for them to sync to keep them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              style: destructive(context),
              child: const Text('Sign out anyway'),
            ),
          ],
        ),
      );
      if (!(confirmed ?? false)) return;
    }
    signOut();
  }

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
    final gameSystems = await widget.vault.gameSystems();
    if (!mounted) return;
    final picked = await showDialog<(String, String?, String)>(
      context: context,
      builder: (_) =>
          NewCollectionDialog(workflows: workflows, gameSystems: gameSystems),
    );
    if (picked case (final name, final workflowId, final gameSystem)
        when mounted) {
      await attempt(
        context,
        () => widget.vault.createCollection(
          name,
          workflowId: workflowId,
          gameSystem: gameSystem,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder(
    stream: _collections,
    builder: (context, snapshot) => Scaffold(
      appBar: AppBar(
        title: const Text('Collections'),
        actions: [
          SyncIcon(db: widget.db, onSyncNow: widget.onSyncNow),
          PopupMenuButton<VoidCallback>(
            tooltip: 'Account',
            onSelected: (action) => action(),
            itemBuilder: (context) => [
              if (widget.email case final email?)
                PopupMenuItem(enabled: false, child: Text(email)),
              PopupMenuItem(
                value: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => WorkflowsScreen(vault: widget.vault),
                  ),
                ),
                child: const Text('Workflows'),
              ),
              if (widget.onSignOut case final signOut?)
                PopupMenuItem(
                  value: () => _signOut(signOut),
                  child: const Text('Sign out'),
                ),
              if (widget.onDeleteAccount case final delete?) ...[
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: delete,
                  child: Text(
                    'Delete account',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          SyncBanner(db: widget.db),
          Expanded(
            child: Builder(
              builder: (context) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Could not load Collections: ${snapshot.error}',
                    ),
                  );
                }
                final collections = snapshot.data;
                if (collections == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (collections.isEmpty) {
                  return const Center(child: Text('No Collections yet'));
                }
                final groups = groupByGameSystem(collections);
                // Headers only once some Collection has a Game System; until then the list is as before.
                final headed = groups.any((g) => g.gameSystem != null);
                return ListView(
                  children: [
                    StreamBuilder(
                      stream: _recent,
                      builder: (context, recent) => switch (recent.data) {
                        null || [] => const SizedBox.shrink(),
                        final squads => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                              child: Text(
                                'Recently painted',
                                style: stencil(
                                  Theme.of(context).textTheme.titleSmall,
                                ),
                              ),
                            ),
                            for (final r in squads)
                              ListTile(
                                title: Text(r.squad.name),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(r.collection.name),
                                    const SizedBox(height: 4),
                                    StageBar(r.squad.progress),
                                  ],
                                ),
                                onTap: () => showMoveSheet(
                                  context,
                                  widget.vault,
                                  r.collection,
                                  r.squad,
                                  r.from,
                                  // shortcut: no recount from here, it needs the Squad screen; open it for that.
                                  onDetails: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => SquadScreen(
                                        vault: widget.vault,
                                        photos: widget.photos,
                                        collection: r.collection,
                                        name: r.squad.name,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            const Divider(),
                          ],
                        ),
                      },
                    ),
                    for (final g in groups) ...[
                      if (headed)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Text(
                            g.gameSystem ?? 'Other',
                            style: stencil(
                              Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                        ),
                      for (final c in g.collections)
                        ListTile(
                          key: ValueKey(c.id),
                          title: Text(c.name),
                          // Keyed by Workflow, so switching it restarts the watch on the new one.
                          subtitle: ProgressSummary(
                            key: ValueKey(c.workflowId),
                            vault: widget.vault,
                            collection: c,
                          ),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => CollectionScreen(
                                vault: widget.vault,
                                db: widget.db,
                                photos: widget.photos,
                                collection: c,
                                onSyncNow: widget.onSyncNow,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        ],
      ),
      bottomNavigationBar: StreamBuilder(
        stream: _progress,
        builder: (context, progress) => ProgressDrawer(
          count: progress.hasData ? snapshot.data?.length ?? 0 : 0,
          noun: 'Collection',
          workflows: progress.data ?? const [],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _create,
        tooltip: 'New Collection',
        child: const Icon(Icons.add),
      ),
    ),
  );
}

/// A Collection's Squads, by name, each with its model count and progress.
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({
    super.key,
    required this.vault,
    required this.db,
    this.photos,
    required this.collection,
    this.onSyncNow,
  });

  final Vault vault;

  /// For the sync status only; Units go through [vault].
  final PowerSyncDatabase db;
  final PhotoFiles? photos;
  final Collection collection;
  final Future<void> Function()? onSyncNow;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  // Kept current, so a rename shows in the title and a Workflow switch restarts the watches below.
  late var _collection = widget.collection;
  late var _squads = widget.vault.watchSquads(_collection);
  late var _progress = widget.vault.watchProgressByWorkflow(_collection);
  late final StreamSubscription<List<Collection>> _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = widget.vault.watchCollections().listen((collections) {
      for (final c in collections) {
        if (c.id != _collection.id) continue;
        setState(() {
          if (c.workflowId != _collection.workflowId) {
            _squads = widget.vault.watchSquads(c);
            _progress = widget.vault.watchProgressByWorkflow(c);
          }
          _collection = c;
        });
      }
    });
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }

  Future<void> _edit(Collection collection) async {
    final gameSystems = await widget.vault.gameSystems();
    if (!mounted) return;
    final edited = await showDialog<(String, String?, String)>(
      context: context,
      builder: (_) =>
          NewCollectionDialog(gameSystems: gameSystems, collection: collection),
    );
    if (edited case (final name, _, final gameSystem) when mounted) {
      // Only changed fields, so an edit to the other field on another device is kept.
      await attempt(context, () async {
        if (name.trim() != collection.name) {
          await widget.vault.renameCollection(collection.id, name);
        }
        if (validGameSystem(gameSystem) != collection.gameSystem) {
          await widget.vault.setGameSystem(collection.id, gameSystem);
        }
      });
    }
  }

  /// Asks first, saying how many Units and models go with the Collection; back to the Collections once deleted.
  Future<void> _delete(Collection collection) async {
    final units = await widget.vault.unitsOf(collection);
    if (!mounted) return;
    final models = units.fold(0, (sum, u) => sum + u.modelCount);
    String count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${collection.name}?'),
        content: Text(
          'Its ${count(units.length, 'Unit')} (${count(models, 'model')}) and their history, '
          'Tags and photos will be deleted on all your devices.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: destructive(context),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    await widget.vault.deleteCollection(collection.id);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: _squads,
      builder: (context, snapshot) {
        final squads = snapshot.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(_collection.name),
            actions: [
              SyncIcon(db: widget.db, onSyncNow: widget.onSyncNow),
              PopupMenuButton<VoidCallback>(
                tooltip: 'Collection',
                onSelected: (action) => action(),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: () => _edit(_collection),
                    child: const Text('Edit Collection'),
                  ),
                  PopupMenuItem(
                    value: () =>
                        switchWorkflow(context, widget.vault, _collection),
                    child: const Text('Switch Workflow'),
                  ),
                  const PopupMenuDivider(),
                  PopupMenuItem(
                    value: () => _delete(_collection),
                    child: Text(
                      'Delete Collection',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              SyncBanner(db: widget.db),
              Expanded(
                child: switch (snapshot) {
                  AsyncSnapshot(:final error?) => Center(
                    child: Text('Could not load Units: $error'),
                  ),
                  _ when squads == null => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  _ => ListView(
                    children: [
                      for (final squad in squads)
                        ListTile(
                          leading: SquadThumbnail(
                            key: ValueKey(squad.name),
                            files: widget.photos,
                            collectionId: _collection.id,
                            squadName: squad.name,
                          ),
                          title: Text(squad.name),
                          subtitle: StageBar(squad.progress),
                          trailing: Text(modelCountText(squad.modelCount)),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SquadScreen(
                                vault: widget.vault,
                                photos: widget.photos,
                                collection: _collection,
                                name: squad.name,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                },
              ),
            ],
          ),
          bottomNavigationBar: StreamBuilder(
            stream: _progress,
            builder: (context, progress) => ProgressDrawer(
              count: progress.hasData ? squads?.length ?? 0 : 0,
              noun: 'Squad',
              workflows: progress.data ?? const [],
            ),
          ),
          floatingActionButton: squads == null
              ? null
              : FloatingActionButton(
                  onPressed: () => addUnit(context, widget.vault, _collection, [
                    for (final s in squads) s.name,
                  ]),
                  tooltip: 'New Unit',
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }
}

/// Asks for a New Unit in [collection], its Name prefilled with [name] and suggested from [squadNames], its Stage
/// starting at the Owned Stage; then adds it.
Future<void> addUnit(
  BuildContext context,
  Vault vault,
  Collection collection,
  List<String> squadNames, {
  String name = '',
}) async {
  final workflow = await vault.workflowOf(collection);
  if (!context.mounted) return;
  final result = await showDialog<_UnitFields>(
    context: context,
    builder: (_) => _UnitDialog(
      title: 'New Unit',
      name: name,
      squadNames: squadNames,
      stages: workflow.stages,
      stageId: workflow.ownedStage.id,
      suggestTags: vault.suggestTags,
    ),
  );
  if (result == null) return;
  final unit = await vault.addUnit(
    collection,
    name: result.name,
    modelCount: result.modelCount,
    notes: result.notes,
    stageId: result.stageId!,
  );
  await vault.addTags(unit.id, result.tags);
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

  /// Moves the whole Unit, or Splits it when fewer models than it has are moved.
  Future<void> _move(Unit unit, List<Stage> stages) async {
    final count = TextEditingController(text: '${unit.modelCount}');
    final stageId = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Move to Stage'),
        children: [
          if (unit.modelCount > 1)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: TextField(
                controller: count,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Models to move',
                  helperText: 'Fewer than ${unit.modelCount} splits the Unit',
                ),
              ),
            ),
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
    // Not disposed: the closing dialog's TextField still uses it; with no listeners left, it is just collected.
    final n = int.tryParse(count.text.trim()) ?? 0;
    if (stageId != null && mounted) {
      await attempt(
        context,
        () => n == unit.modelCount
            ? widget.vault.moveUnit(unit, stageId)
            : widget.vault.splitUnit(unit, stageId, n),
      );
    }
  }

  /// Merges a chosen matching Unit into [unit], only on explicit confirmation.
  Future<void> _merge(Unit unit, List<Unit> candidates) async {
    final other = await showDialog<Unit>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Merge into this Unit'),
        children: [
          for (final u in candidates)
            ListTile(
              title: Text(u.name),
              subtitle: Text(u.notes),
              trailing: Text('${u.modelCount}'),
              onTap: () => Navigator.pop(context, u),
            ),
        ],
      ),
    );
    if (other != null && mounted) {
      await attempt(context, () => widget.vault.mergeUnits(unit, other));
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
            _ when unit == null && !snapshot.hasData => const Center(
              child: CircularProgressIndicator(),
            ),
            // A move onto a Stage with a matching Unit Merges this one into it (ADR 0004).
            _ when unit == null => const Center(
              child: Text('This Unit was merged into another or deleted.'),
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
                // Always one slot, so the History StreamBuilder below keeps its place and its single subscription.
                switch (Vault.mergeCandidates(
                  unit,
                  groups.expand((g) => g.units),
                )) {
                  [] => const SizedBox.shrink(),
                  final candidates => ListTile(
                    title: Text(
                      candidates.length == 1
                          ? '1 matching Unit at this Stage'
                          : '${candidates.length} matching Units at this Stage',
                    ),
                    trailing: OutlinedButton(
                      onPressed: () => _merge(unit, candidates),
                      child: const Text('Merge'),
                    ),
                  ),
                },
                if (unit.notes.isNotEmpty) ListTile(title: Text(unit.notes)),
                ListTile(
                  title: Text(
                    'History',
                    style: stencil(Theme.of(context).textTheme.titleMedium),
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

/// Adds a Unit (with a starting Stage from [stages], [stageId] first) or edits [unit] (with a Delete button).
class _UnitDialog extends StatefulWidget {
  const _UnitDialog({
    required this.title,
    this.name,
    this.squadNames = const [],
    this.stages = const [],
    this.stageId,
    this.unit,
    this.tags = const [],
    required this.suggestTags,
  });

  final String title;
  final String? name;

  /// The Collection's Squad names, suggested as the Name is typed.
  final List<String> squadNames;
  final List<Stage> stages;
  final String? stageId;
  final Unit? unit;
  final List<String> tags;
  final Future<List<String>> Function(String prefix) suggestTags;

  @override
  State<_UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<_UnitDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.unit?.name ?? widget.name,
  );
  final _nameFocus = FocusNode();
  late final _count = TextEditingController(
    text: '${widget.unit?.modelCount ?? 1}',
  );
  late final _notes = TextEditingController(text: widget.unit?.notes);
  late String? _stageId = widget.stageId ?? widget.stages.firstOrNull?.id;
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
    _nameFocus.dispose();
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
              Autocomplete<String>(
                textEditingController: _name,
                focusNode: _nameFocus,
                optionsBuilder: (value) {
                  final typed = value.text.trim().toLowerCase();
                  return [
                    for (final n in widget.squadNames)
                      if (typed.isNotEmpty &&
                          n != value.text &&
                          n.toLowerCase().contains(typed))
                        n,
                  ];
                },
                fieldViewBuilder: (context, field, focus, submit) =>
                    TextFormField(
                      controller: field,
                      focusNode: focus,
                      autofocus: widget.unit == null,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (v) =>
                          v!.trim().isEmpty ? 'Enter a name' : null,
                    ),
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
            style: destructive(context),
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

/// Keeps [status] and [waiting] (the unsynced count, see [watchUnsynced]) of [db] up to date.
mixin _WatchSync<T extends StatefulWidget> on State<T> {
  PowerSyncDatabase get db;
  late SyncStatus status = db.currentStatus;
  int waiting = 0;
  late final List<StreamSubscription<void>> _subscriptions;

  void onWaiting(int n) {}

  @override
  void initState() {
    super.initState();
    _subscriptions = [
      db.statusStream.listen((s) => setState(() => status = s)),
      watchUnsynced(db).listen((n) {
        onWaiting(n);
        setState(() => waiting = n);
      }),
    ];
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }
}

/// A cloud in the app bar: crossed out offline, with a badge counting the local changes still waiting to upload.
/// Connected, tapping it syncs now.
class SyncIcon extends StatefulWidget {
  const SyncIcon({super.key, required this.db, this.onSyncNow});

  final PowerSyncDatabase db;

  /// Null hides Sync now.
  final Future<void> Function()? onSyncNow;

  @override
  State<SyncIcon> createState() => _SyncIconState();
}

class _SyncIconState extends State<SyncIcon> with _WatchSync {
  @override
  PowerSyncDatabase get db => widget.db;
  bool _syncing = false;

  Future<void> _syncNow(Future<void> Function() syncNow) async {
    setState(() => _syncing = true);
    try {
      await syncNow();
    } on Exception {
      // No popup: the count staying up shows it did not sync.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: switch ((waiting, status.connected)) {
      (0, true) => 'All changes synced',
      (0, false) => 'Offline',
      (1, _) => '1 change waiting to sync',
      (final n, _) => '$n changes waiting to sync',
    },
    onPressed: switch (widget.onSyncNow) {
      final syncNow? when status.connected && !_syncing => () => _syncNow(
        syncNow,
      ),
      _ => null,
    },
    // Disabled only for want of a connection or while syncing: keep the icon's colour.
    disabledColor: IconTheme.of(context).color,
    icon: _syncing
        ? const SizedBox.square(
            dimension: 24,
            child: Padding(
              padding: EdgeInsets.all(2),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : Badge.count(
            count: waiting,
            isLabelVisible: waiting > 0,
            child: Icon(status.connected ? Icons.cloud : Icons.cloud_off),
          ),
  );
}

/// A full-width warning, shown only when syncing failed or changes have waited to upload for over a day.
class SyncBanner extends StatefulWidget {
  const SyncBanner({super.key, required this.db, this.now = DateTime.now});

  final PowerSyncDatabase db;
  final DateTime Function() now;

  @override
  State<SyncBanner> createState() => _SyncBannerState();
}

class _SyncBannerState extends State<SyncBanner> with _WatchSync {
  // shortcut: ps_crud has no timestamps, so "waiting since" is when this app run first saw changes waiting (kept per
  // database across screens); restarting the app restarts the clock. Record the time in a local-only table if
  // stale changes go unnoticed.
  static final _waitingSince = Expando<DateTime>();
  static const _staleAfter = Duration(days: 1);
  Timer? _stale;

  @override
  PowerSyncDatabase get db => widget.db;

  @override
  void onWaiting(int n) {
    _stale?.cancel();
    if (n == 0) {
      _waitingSince[db] = null;
      return;
    }
    final since = _waitingSince[db] ??= widget.now();
    final left = since.add(_staleAfter).difference(widget.now());
    // Rebuilds when the changes turn stale, even with nothing else happening (offline).
    if (!left.isNegative) _stale = Timer(left, () => setState(() {}));
  }

  @override
  void dispose() {
    _stale?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final since = _waitingSince[db];
    final text = switch (status.anyError) {
      final error? => 'Sync failed: $error',
      _
          when waiting > 0 &&
              since != null &&
              widget.now().difference(since) >= _staleAfter =>
        "Changes haven't synced for over a day. Connect to the internet to keep them.",
      _ => null,
    };
    if (text == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: SizedBox(
          width: double.infinity,
          child: Text(text, style: TextStyle(color: colors.onErrorContainer)),
        ),
      ),
    );
  }
}
