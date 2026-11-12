/// Mini Vault's write API: applies the app's uploaded writes (PowerSync's upload queue) to Postgres.
library;

import 'dart:convert';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:domain_core/domain_core.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

/// The columns a client may write, per synced table, with their Postgres types.
/// `id` and `owner_id` are never taken from the payload: the owner is the authenticated user.
const _writable = {
  'workflows': {
    'name': 'text',
    'owned_stage_id': 'uuid',
    'finished_stage_id': 'uuid',
  },
  'stages': {'workflow_id': 'uuid', 'name': 'text', 'position': 'int'},
  'collections': {'name': 'text', 'workflow_id': 'uuid'},
  'units': {
    'collection_id': 'uuid',
    'stage_id': 'uuid',
    'name': 'text',
    'model_count': 'int',
    'notes': 'text',
  },
};

/// Columns that point at another synced row, and that row's table. The row must exist and be the user's own.
// owned_stage_id and finished_stage_id are left out: a Workflow is created before its Stages.
const _references = {
  'workflow_id': 'workflows',
  'collection_id': 'collections',
  'stage_id': 'stages',
};

/// Creates the synced tables, the trigger that gives each new account its starter Workflow,
/// and the publication PowerSync replicates from. Idempotent; run after GoTrue has created `auth.users`.
Future<void> migrate(Session db) =>
    db.execute(_migration, queryMode: QueryMode.simple);

final _migration =
    '''
CREATE TABLE IF NOT EXISTS workflows (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  name text NOT NULL,
  owned_stage_id uuid NOT NULL,
  finished_stage_id uuid NOT NULL
);
-- Marks the account's starter Workflow, the default for a new Collection. Not writable by clients.
ALTER TABLE workflows ADD COLUMN IF NOT EXISTS starter boolean NOT NULL DEFAULT false;
CREATE TABLE IF NOT EXISTS stages (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  workflow_id uuid NOT NULL,
  name text NOT NULL,
  position integer NOT NULL
);
CREATE TABLE IF NOT EXISTS collections (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  name text NOT NULL,
  workflow_id uuid NOT NULL
);
CREATE TABLE IF NOT EXISTS units (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  collection_id uuid NOT NULL,
  stage_id uuid NOT NULL,
  name text NOT NULL,
  model_count integer NOT NULL CHECK (model_count >= 1),
  notes text NOT NULL DEFAULT ''
);

-- Runs as its owner, since GoTrue's own role inserts into auth.users.
CREATE OR REPLACE FUNCTION public.create_starter_workflow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS \$\$
DECLARE
  stage_names text[] := ARRAY[${Vault.starterStageNames.map(_quote).join(', ')}];
  stage_ids uuid[] := ARRAY(SELECT gen_random_uuid() FROM unnest(stage_names));
  new_workflow_id uuid := gen_random_uuid();
BEGIN
  -- The Owned Stage is the second Stage and the Finished Stage the last, as the glossary defaults say.
  INSERT INTO workflows (id, owner_id, name, owned_stage_id, finished_stage_id, starter)
  VALUES (new_workflow_id, NEW.id, 'Starter', stage_ids[2], stage_ids[array_length(stage_ids, 1)], true);
  INSERT INTO stages (id, owner_id, workflow_id, name, position)
  SELECT stage_ids[i], NEW.id, new_workflow_id, stage_names[i], i - 1
  FROM generate_subscripts(stage_names, 1) AS i;
  RETURN NEW;
END
\$\$;
DROP TRIGGER IF EXISTS create_starter_workflow ON auth.users;
CREATE TRIGGER create_starter_workflow AFTER INSERT ON auth.users
FOR EACH ROW EXECUTE FUNCTION public.create_starter_workflow();

-- PowerSync replicates these tables. A new synced table must be added to this list too; existing databases get it added.
DO \$\$ DECLARE t text; BEGIN
  IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'powersync') THEN
    CREATE PUBLICATION powersync;
  END IF;
  FOR t IN SELECT unnest(ARRAY['workflows', 'stages', 'collections', 'units'])
    EXCEPT SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync'
  LOOP
    EXECUTE format('ALTER PUBLICATION powersync ADD TABLE %I', t);
  END LOOP;
END \$\$;
''';

String _quote(String s) => "'${s.replaceAll("'", "''")}'";

/// `POST /upload` with `{"operations": [CrudEntry.toJson(), ...]}` and the user's GoTrue access token.
/// Applies the operations in one transaction. Answers 401 for a bad token, 403 if any operation touches
/// or points at another user's row, 409 for deleting a Workflow a Collection uses or a Stage that holds Units,
/// 422 for an invalid operation (including a reference to a missing row) or a batch that leaves a Workflow invalid
/// (nothing is written in those cases), and 204 on success.
/// Conflicts are the latest write wins per field, and deletes win: a PATCH to a deleted row is ignored.
Handler writeApi(Pool<void> db, {required String jwtSecret}) =>
    (request) async {
      if (request.url.path != 'upload') return Response.notFound(null);
      if (request.method != 'POST') return Response(405);

      final String owner;
      try {
        final header = request.headers['authorization'] ?? '';
        final jwt = JWT.verify(
          header.startsWith('Bearer ') ? header.substring(7) : '',
          SecretKey(jwtSecret),
          audience: Audience.one('authenticated'),
        );
        owner = jwt.subject ?? (throw JWTInvalidException('no sub'));
      } on JWTException catch (e) {
        return _error(401, e.message);
      }

      final List<Map<String, Object?>> operations;
      try {
        final body = jsonDecode(await request.readAsString()) as Map;
        operations = [
          for (final op in body['operations'] as List)
            op as Map<String, Object?>,
        ];
      } catch (_) {
        return _error(400, 'Expected {"operations": [...]}');
      }

      try {
        await db.runTx((tx) async {
          final touched = <String>{};
          for (final op in operations) {
            touched.addAll(await _apply(tx, owner, op));
          }
          await _checkWorkflows(tx, touched);
        });
        return Response(204);
      } on _Rejected catch (e) {
        return _error(e.status, e.message);
      } on ServerException catch (e) {
        // Class 22 (bad data, e.g. a malformed UUID) and 23 (a constraint, e.g. a missing column) are the client's fault.
        if (e.code case final code?
            when code.startsWith('22') || code.startsWith('23')) {
          return _error(422, e.message);
        }
        rethrow;
      }
    };

/// Applies [op] and returns the ids of the Workflows it may have changed, to check once the batch is applied.
Future<Set<String>> _apply(
  TxSession tx,
  String owner,
  Map<String, Object?> op,
) async {
  final table = op['type'];
  final id = op['id'];
  final data = op['data'] as Map<String, Object?>? ?? {};
  final types = _writable[table];
  if (types == null || id is! String) {
    throw _Rejected(422, 'Unknown table $table or missing id');
  }
  if (data.keys.where((c) => !types.containsKey(c)) case final extra
      when extra.isNotEmpty) {
    throw _Rejected(422, 'Columns not writable on $table: ${extra.join(', ')}');
  }
  if (data['name'] case final name?) {
    try {
      data['name'] = validName(name as String);
    } on ArgumentError catch (e) {
      throw _Rejected(422, '${e.message}');
    }
  }

  final existing = await tx.execute(
    'SELECT owner_id::text FROM $table WHERE id = \$1::uuid FOR UPDATE',
    parameters: [id],
  );
  if (existing.isNotEmpty && existing.first.first != owner) {
    throw _Rejected(403, 'Not your row: $table $id');
  }

  // Skipped for a PATCH to a deleted row, which is ignored anyway (deletes win).
  // FOR SHARE holds off a concurrent delete of the referenced row until this batch commits.
  if (existing.isNotEmpty || op['op'] == 'PUT') {
    for (final column in data.keys.where(_references.containsKey)) {
      final referenced = await tx.execute(
        'SELECT owner_id::text FROM ${_references[column]} WHERE id = \$1::uuid FOR SHARE',
        parameters: [data[column]],
      );
      if (referenced.isEmpty) {
        throw _Rejected(422, '$column ${data[column]} does not exist');
      }
      if (referenced.first.first != owner) {
        throw _Rejected(403, 'Not your row: $column ${data[column]}');
      }
    }
  }
  // A Stage holding Units can't be deleted or moved to another Workflow: its Units would lose their place.
  if (table == 'stages' &&
      (op['op'] == 'DELETE' || data.containsKey('workflow_id'))) {
    final held = await tx.execute(
      'SELECT FROM units WHERE stage_id = \$1::uuid LIMIT 1',
      parameters: [id],
    );
    if (held.isNotEmpty) throw _Rejected(409, 'Units are at Stage $id');
  }
  if (table == 'workflows' && op['op'] == 'DELETE') {
    final used = await tx.execute(
      'SELECT FROM collections WHERE workflow_id = \$1::uuid LIMIT 1',
      parameters: [id],
    );
    if (used.isNotEmpty) throw _Rejected(409, 'A Collection uses Workflow $id');
  }
  final touched = {
    if (table == 'workflows') id,
    if (table == 'stages') ...[
      for (final row in await tx.execute(
        'SELECT workflow_id::text FROM stages WHERE id = \$1::uuid',
        parameters: [id],
      ))
        row.first as String,
      if (data['workflow_id'] case final String workflowId) workflowId,
    ],
  };

  // Column names come from _writable, never from the payload, so interpolating them is safe.
  final columns = data.keys.toList();
  final values = [id, owner, ...data.values];
  String param(int i, String type) => '\$${i + 3}::$type';
  final sets = [
    for (final (i, c) in columns.indexed) '$c = ${param(i, types[c]!)}',
  ];

  switch (op['op']) {
    case 'PUT' when existing.isEmpty:
      await tx.execute(
        'INSERT INTO $table (id, owner_id${columns.map((c) => ', $c').join()}) '
        'VALUES (\$1::uuid, \$2::uuid${[for (final (i, c) in columns.indexed) ', ${param(i, types[c]!)}'].join()})',
        parameters: values,
      );
    case 'PUT' || 'PATCH' when sets.isNotEmpty:
      await tx.execute(
        'UPDATE $table SET ${sets.join(', ')} WHERE id = \$1::uuid AND owner_id = \$2::uuid',
        parameters: values,
      );
    case 'PUT' || 'PATCH':
      break;
    case 'DELETE':
      await tx.execute(
        'DELETE FROM $table WHERE id = \$1::uuid AND owner_id = \$2::uuid',
        parameters: [id, owner],
      );
    default:
      throw _Rejected(422, 'Unknown op ${op['op']}');
  }

  // Checked after the write, so it holds whichever of the two columns changed. The transaction rolls back if not.
  if (table == 'units') {
    final mismatched = await tx.execute(
      'SELECT FROM units u JOIN collections c ON c.id = u.collection_id JOIN stages s ON s.id = u.stage_id '
      'WHERE u.id = \$1::uuid AND s.workflow_id <> c.workflow_id',
      parameters: [id],
    );
    if (mismatched.isNotEmpty) {
      throw _Rejected(
        422,
        "Unit $id's Stage is not in its Collection's Workflow",
      );
    }
  }
  return touched;
}

/// Rejects the batch if it leaves a (still existing) Workflow without its Owned and Finished Stage among its own
/// Stages, in that order. Checked after the whole batch, since a client writes a new Workflow before its Stages.
/// Stage order is (position, id), as on the client.
Future<void> _checkWorkflows(TxSession tx, Set<String> workflowIds) async {
  if (workflowIds.isEmpty) return;
  final invalid = await tx.execute(
    r'''SELECT w.id::text FROM workflows w
      WHERE w.id::text = ANY($1) AND NOT EXISTS (
        SELECT FROM stages o, stages f
        WHERE o.id = w.owned_stage_id AND o.workflow_id = w.id
          AND f.id = w.finished_stage_id AND f.workflow_id = w.id
          AND (o.position, o.id) <= (f.position, f.id))''',
    parameters: [TypedValue(Type.textArray, workflowIds.toList())],
  );
  if (invalid.isNotEmpty) {
    throw _Rejected(
      422,
      'Workflow ${invalid.first.first}: its Owned and Finished Stage must be its own Stages, in that order',
    );
  }
}

Response _error(int status, String message) => Response(
  status,
  body: jsonEncode({'error': message}),
  headers: {'content-type': 'application/json'},
);

class _Rejected implements Exception {
  _Rejected(this.status, this.message);
  final int status;
  final String message;
}
