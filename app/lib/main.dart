import 'dart:async';
import 'dart:io';

import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:gotrue/gotrue.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' hide Column;

import 'account.dart';
import 'army_list.dart';
import 'paints.dart';
import 'photos.dart';
import 'progress.dart';
import 'unit.dart';
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
  // Batches meeting at a Stage through sync are Merged here, once for the whole app (ADR 0009).
  Vault(SqliteVaultStore(db)).keepBatchesMerged().listen(
    null,
    onError: (Object e) => debugPrint('Automatic Merge failed: $e'),
  );
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
        builder: (context, _) {
          if (auth.currentSession == null) return SignInScreen(auth: auth);
          final vault = Vault(SqliteVaultStore(db));
          return HomeScreen(
            vault: vault,
            photos: photos,
            collections: CollectionsScreen(
              vault: vault,
              db: db,
              photos: photos,
              email: auth.currentUser?.email,
              onSignOut: auth.signOut,
              onSyncNow: () => syncNow(auth, db, photos.queue),
              onDeleteAccount: () => deleteAccount(context, auth),
            ),
          );
        },
      ),
    );
  }
}

/// Collections, Paints and Workflows as bottom tabs, each with its own back stack.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.vault,
    required this.collections,
    this.photos,
  });

  final Vault vault;

  /// The first tab, on the same [vault].
  final Widget collections;

  /// Passed on to the Paints tab.
  final PhotoFiles? photos;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _navigators = List.generate(3, (_) => GlobalKey<NavigatorState>());
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final tabs = [
      widget.collections,
      PaintsScreen(vault: widget.vault, photos: widget.photos),
      WorkflowsScreen(vault: widget.vault),
    ];
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          for (final (i, tab) in tabs.indexed)
            // System back pops the open tab's stack before leaving the app.
            NavigatorPopHandler(
              enabled: i == _tab,
              onPopWithResult: (_) => _navigators[i].currentState?.maybePop(),
              child: Navigator(
                key: _navigators[i],
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => tab),
              ),
            ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.collections_bookmark),
            label: 'Collections',
          ),
          NavigationDestination(icon: Icon(Icons.palette), label: 'Paints'),
          NavigationDestination(
            icon: Icon(Icons.account_tree),
            label: 'Workflows',
          ),
        ],
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
  bool _showPassword = false;
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
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(
                tooltip: _showPassword ? 'Hide password' : 'Show password',
                icon: Icon(
                  _showPassword ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _showPassword = !_showPassword),
              ),
            ),
            obscureText: !_showPassword,
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
  late var _collections = widget.vault.watchCollections();
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
              const PopupMenuItem(enabled: false, child: AppVersion()),
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
                if (snapshot.error case final error?) {
                  return LoadError(
                    what: 'your Collections',
                    error: error,
                    onRetry: () => setState(
                      () => _collections = widget.vault.watchCollections(),
                    ),
                  );
                }
                final collections = snapshot.data;
                if (collections == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (collections.isEmpty) {
                  return EmptyState(
                    explanation: 'A Collection is a named set of Units that progress through the same Workflow.',
                    label: 'New Collection',
                    onPressed: _create,
                    alternative: TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ArmyListScreen(vault: widget.vault),
                        ),
                      ),
                      child: const Text('Import army list'),
                    ),
                  );
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
                        final units => Column(
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
                            for (final r in units)
                              ListTile(
                                title: Text(r.unit.name),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(r.collection.name),
                                    const SizedBox(height: 4),
                                    StageBar(r.unit.progress),
                                  ],
                                ),
                                onTap: () => showMoveSheet(
                                  context,
                                  widget.vault,
                                  r.collection,
                                  r.unit.name,
                                  [for (final g in r.unit.stages) g.stage],
                                  // shortcut: no recount from here, it needs the Unit screen; open it for that.
                                  r.from,
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.chevron_right),
                                  tooltip: 'Open ${r.unit.name}',
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => UnitScreen(
                                        vault: widget.vault,
                                        photos: widget.photos,
                                        collection: r.collection,
                                        name: r.unit.name,
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

/// An empty screen: one line on what belongs here and a large button to add the first one.
/// A stream that failed: a plain sentence and Retry; the exception goes to the log, not the screen.
class LoadError extends StatelessWidget {
  const LoadError({
    super.key,
    required this.what,
    required this.error,
    required this.onRetry,
  });

  /// What could not be loaded, e.g. "the Paints".
  final String what;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    debugPrint('Could not load $what: $error');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Could not load $what.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.explanation,
    required this.label,
    required this.onPressed,
    this.alternative,
  });

  final String explanation;
  final String label;
  final VoidCallback onPressed;

  /// A second way to add, shown under the button.
  final Widget? alternative;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(explanation, textAlign: TextAlign.center),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.add),
            label: Text(label),
            style: FilledButton.styleFrom(minimumSize: const Size(200, 56)),
          ),
          if (alternative case final alternative?) ...[
            const SizedBox(height: 8),
            alternative,
          ],
        ],
      ),
    ),
  );
}

/// A Collection's Units, by name, each with its model count and progress.
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

  /// For the sync status only; Batches go through [vault].
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
  late var _units = widget.vault.watchUnits(_collection);
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
            _units = widget.vault.watchUnits(c);
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
    final batches = await widget.vault.batchesOf(collection);
    if (!mounted) return;
    final units = {for (final b in batches) b.name}.length;
    final models = batches.fold(0, (sum, u) => sum + u.modelCount);
    String count(int n, String noun) => n == 1 ? '1 $noun' : '$n ${noun}s';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${collection.name}?'),
        content: Text(
          'Its ${count(units, 'Unit')} (${count(models, 'model')}) and their history, '
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
      stream: _units,
      builder: (context, snapshot) {
        final units = snapshot.data;
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
                  PopupMenuItem(
                    value: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ArmyListScreen(
                          vault: widget.vault,
                          collection: _collection,
                        ),
                      ),
                    ),
                    child: const Text('Import army list'),
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
                  AsyncSnapshot(:final error?) => LoadError(
                    what: 'the Units',
                    error: error,
                    onRetry: () => setState(
                      () => _units = widget.vault.watchUnits(_collection),
                    ),
                  ),
                  _ when units == null => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  _ when units.isEmpty => EmptyState(
                    explanation: 'A Unit is all the models you track under one name, like "Intercessors", wherever they are in your Workflow.',
                    label: 'Add models',
                    onPressed: () =>
                        addModels(context, widget.vault, _collection, const []),
                  ),
                  _ => ListView(
                    children: [
                      for (final unit in units)
                        ListTile(
                          leading: UnitThumbnail(
                            key: ValueKey(unit.name),
                            vault: widget.vault,
                            files: widget.photos,
                            collectionId: _collection.id,
                            unitName: unit.name,
                          ),
                          title: Text(unit.name),
                          subtitle: StageBar(unit.progress),
                          trailing: Text(modelCountText(unit.modelCount)),
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => UnitScreen(
                                vault: widget.vault,
                                photos: widget.photos,
                                collection: _collection,
                                name: unit.name,
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
              count: progress.hasData ? units?.length ?? 0 : 0,
              noun: 'Unit',
              workflows: progress.data ?? const [],
            ),
          ),
          floatingActionButton: units == null
              ? null
              : FloatingActionButton(
                  onPressed: () => addModels(
                    context,
                    widget.vault,
                    _collection,
                    [for (final s in units) s.name],
                  ),
                  tooltip: 'Add models',
                  child: const Icon(Icons.add),
                ),
        );
      },
    );
  }
}

/// Asks for a name (prefilled with [name], suggested from [unitNames]), a model count and a Stage (the Owned Stage to
/// start with), then adds that many models at it to the Unit of that name in [collection], creating it if new.
Future<void> addModels(
  BuildContext context,
  Vault vault,
  Collection collection,
  List<String> unitNames, {
  String name = '',
}) async {
  final workflow = await vault.workflowOf(collection);
  if (!context.mounted) return;
  final result = await showDialog<UnitFields>(
    context: context,
    builder: (_) => UnitDialog(
      title: 'Add models',
      name: name,
      unitNames: unitNames,
      stages: workflow.stages,
      stageId: workflow.ownedStage.id,
      suggestTags: vault.suggestTags,
    ),
  );
  if (result == null) return;
  // A Batch of the Unit already at that Stage takes these in through the automatic Merge (ADR 0009).
  await vault.addBatch(
    collection,
    name: result.name,
    modelCount: result.modelCount,
    stageId: result.stageId!,
  );
}

typedef UnitFields = ({
  String name,
  int modelCount,
  String notes,
  String? stageId,
  List<String> tags,
});

/// Adds models (name, count and a starting Stage from [stages], [stageId] first) or, without [stages], edits a Unit
/// (name, [notes] and [tags]).
class UnitDialog extends StatefulWidget {
  const UnitDialog({
    super.key,
    required this.title,
    this.name,
    this.unitNames = const [],
    this.stages = const [],
    this.stageId,
    this.notes = '',
    this.tags = const [],
    required this.suggestTags,
  });

  final String title;
  final String? name;

  /// The Collection's Unit names, suggested as the Name is typed.
  final List<String> unitNames;
  final List<Stage> stages;
  final String? stageId;

  /// The Unit's notes, when editing.
  final String notes;
  final List<String> tags;
  final Future<List<String>> Function(String prefix) suggestTags;

  @override
  State<UnitDialog> createState() => _UnitDialogState();
}

class _UnitDialogState extends State<UnitDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.name);
  final _nameFocus = FocusNode();
  final _count = TextEditingController(text: '1');
  late final _notes = TextEditingController(text: widget.notes);
  late String? _stageId = widget.stageId ?? widget.stages.firstOrNull?.id;
  late final _tags = [...widget.tags];
  final _tag = TextEditingController();
  final _tagFocus = FocusNode();

  bool get _adding => widget.stages.isNotEmpty;

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

  void _close() {
    if (!_form.currentState!.validate()) return;
    _addTag(_tag.text); // A Tag typed but not yet submitted.
    Navigator.pop<UnitFields>(context, (
      name: _name.text.trim(),
      modelCount: int.tryParse(_count.text.trim()) ?? 0,
      notes: _notes.text.trim(),
      stageId: _stageId,
      tags: _tags,
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
                    for (final n in widget.unitNames)
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
                      autofocus: _adding,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: (v) =>
                          v!.trim().isEmpty ? 'Enter a name' : null,
                    ),
              ),
              if (_adding) ...[
                TextFormField(
                  controller: _count,
                  decoration: const InputDecoration(labelText: 'Models'),
                  keyboardType: TextInputType.number,
                  validator: (v) =>
                      (int.tryParse(v!.trim()) ?? 0) < 1 ? 'At least 1' : null,
                ),
                DropdownButtonFormField<String>(
                  initialValue: _stageId,
                  decoration: const InputDecoration(labelText: 'Stage'),
                  items: [
                    for (final s in widget.stages)
                      DropdownMenuItem(value: s.id, child: Text(s.name)),
                  ],
                  onChanged: (id) => _stageId = id,
                ),
              ] else ...[
                TextFormField(
                  controller: _notes,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: null,
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
            ],
          ),
        ),
      ),
      actions: [
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
