import 'package:domain_core/domain_core.dart';
import 'package:domain_core/sqlite_store.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite_async/sqlite_async.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final dir = await getApplicationSupportDirectory();
  final db = SqliteDatabase(path: '${dir.path}/mini_vault.db');
  await SqliteVaultStore.createTables(db);
  final vault = Vault(SqliteVaultStore(db));
  await vault.ensureStarterWorkflow();
  runApp(MiniVaultApp(vault: vault));
}

class MiniVaultApp extends StatelessWidget {
  const MiniVaultApp({super.key, required this.vault});

  final Vault vault;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mini Vault',
      home: CollectionsScreen(vault: vault),
    );
  }
}

class CollectionsScreen extends StatefulWidget {
  const CollectionsScreen({super.key, required this.vault});

  final Vault vault;

  @override
  State<CollectionsScreen> createState() => _CollectionsScreenState();
}

class _CollectionsScreenState extends State<CollectionsScreen> {
  late Future<List<Collection>> _collections = widget.vault.collections();

  Future<void> _create() async {
    final name = await _askName('New Collection', '');
    if (name == null) return;
    await widget.vault.createCollection(name);
    setState(() => _collections = widget.vault.collections());
  }

  Future<void> _rename(Collection collection) async {
    final name = await _askName('Rename Collection', collection.name);
    if (name == null) return;
    await widget.vault.renameCollection(collection.id, name);
    setState(() => _collections = widget.vault.collections());
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
      appBar: AppBar(title: const Text('Collections')),
      body: FutureBuilder(
        future: _collections,
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
