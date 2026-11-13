/// Mini Vault's write API: applies the app's uploaded writes (PowerSync's upload queue) to Postgres.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:domain_core/domain_core.dart';
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';

import 'photos.dart';

/// The columns a client may write, per synced table, with their Postgres types.
/// `id` and `owner_id` are never taken from the payload: the owner is the authenticated user.
const _writable = {
  'workflows': {
    'name': 'text',
    'owned_stage_id': 'uuid',
    'finished_stage_id': 'uuid',
  },
  'stages': {
    'workflow_id': 'uuid',
    'name': 'text',
    'position': 'int',
    'colour': 'text',
  },
  'collections': {'name': 'text', 'workflow_id': 'uuid', 'game_system': 'text'},
  'units': {
    'collection_id': 'uuid',
    'stage_id': 'uuid',
    'name': 'text',
    'model_count': 'int',
    'notes': 'text',
  },
  'stage_changes': {
    'unit_id': 'uuid',
    'from_stage_id': 'uuid',
    'to_stage_id': 'uuid',
    'model_count': 'int',
    'happened_at': 'timestamptz',
  },
  'unit_tags': {'unit_id': 'uuid', 'name': 'text'},
  'photos': {'unit_id': 'uuid', 'file_id': 'uuid'},
  'splits': {'unit_id': 'uuid', 'new_unit_id': 'uuid', 'model_count': 'int'},
  'merges': {'unit_id': 'uuid', 'merged_unit_id': 'uuid'},
  'paints': {'brand': 'text', 'range': 'text', 'name': 'text', 'owned': 'int'},
};

/// Columns that point at another synced row, and that row's table. The row must exist and be the user's own.
// owned_stage_id and finished_stage_id are left out: a Workflow is created before its Stages.
const _references = {
  'workflow_id': 'workflows',
  'collection_id': 'collections',
  'stage_id': 'stages',
  'unit_id': 'units',
  'from_stage_id': 'stages',
  'to_stage_id': 'stages',
  'new_unit_id': 'units',
  'merged_unit_id': 'units',
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
-- `#RRGGBB` (see stageColourFormat). Stages from before colours get Vault.stageColours by their place in the Workflow.
ALTER TABLE stages ADD COLUMN IF NOT EXISTS colour text;
UPDATE stages s SET colour = (ARRAY[${Vault.stageColours.map(_quote).join(', ')}])[n.i % ${Vault.stageColours.length} + 1]
FROM (SELECT id, row_number() OVER (PARTITION BY workflow_id ORDER BY position, id) - 1 AS i FROM stages) n
WHERE n.id = s.id AND s.colour IS NULL;
ALTER TABLE stages ALTER COLUMN colour SET NOT NULL;
CREATE TABLE IF NOT EXISTS collections (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  name text NOT NULL,
  workflow_id uuid NOT NULL
);
-- Free text; Collections whose Game System matches ignoring case share it (domain_core's tagKey). Null: none.
ALTER TABLE collections ADD COLUMN IF NOT EXISTS game_system text;
CREATE TABLE IF NOT EXISTS units (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  collection_id uuid NOT NULL,
  stage_id uuid NOT NULL,
  name text NOT NULL,
  model_count integer NOT NULL CHECK (model_count >= 1),
  notes text NOT NULL DEFAULT ''
);
-- Append-only. Deleting a Unit deletes its Stage Changes.
CREATE TABLE IF NOT EXISTS stage_changes (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  from_stage_id uuid,
  to_stage_id uuid NOT NULL,
  model_count integer NOT NULL CHECK (model_count >= 1),
  happened_at timestamptz NOT NULL
);
CREATE INDEX IF NOT EXISTS stage_changes_unit_id ON stage_changes (unit_id);
-- A Tag on a Unit. The id is derived from the Unit and the Tag name (domain_core's tagId), so the same Tag added
-- on two devices is one row. Deleted with its Unit.
CREATE TABLE IF NOT EXISTS unit_tags (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  name text NOT NULL
);
CREATE INDEX IF NOT EXISTS unit_tags_unit_id ON unit_tags (unit_id);
-- A photo of a Unit. file_id names the image file on disk (photos.dart); a Split's copy shares it, and the file
-- is deleted once no row points at it. Deleted with its Unit.
CREATE TABLE IF NOT EXISTS photos (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  file_id uuid NOT NULL
);
CREATE INDEX IF NOT EXISTS photos_unit_id ON photos (unit_id);
CREATE INDEX IF NOT EXISTS photos_owner_file ON photos (owner_id, file_id);
-- Append-only deltas on units.model_count, applied once when first stored (see _applyDelta). A Split takes
-- model_count models off unit_id into new_unit_id; a Merge adds merged_unit_id's models to unit_id and deletes it.
CREATE TABLE IF NOT EXISTS splits (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  new_unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  model_count integer NOT NULL CHECK (model_count >= 1)
);
CREATE TABLE IF NOT EXISTS merges (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  unit_id uuid NOT NULL REFERENCES units ON DELETE CASCADE,
  merged_unit_id uuid NOT NULL
);
-- The paint library, one per person, independent of any Collection. owned is 1, wanted 0. Duplicates (brand, range
-- and name alike ignoring case) are refused by the app, not here: two devices offline may each add the same Paint.
CREATE TABLE IF NOT EXISTS paints (
  id uuid PRIMARY KEY,
  owner_id uuid NOT NULL REFERENCES auth.users ON DELETE CASCADE,
  brand text NOT NULL,
  range text NOT NULL,
  name text NOT NULL,
  owned integer NOT NULL CHECK (owned IN (0, 1))
);

-- Runs as its owner, since GoTrue's own role inserts into auth.users.
CREATE OR REPLACE FUNCTION public.create_starter_workflow() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS \$\$
DECLARE
  stage_names text[] := ARRAY[${Vault.starterStageNames.map(_quote).join(', ')}];
  stage_ids uuid[] := ARRAY(SELECT gen_random_uuid() FROM unnest(stage_names));
  stage_colours text[] := ARRAY[${Vault.stageColours.map(_quote).join(', ')}];
  new_workflow_id uuid := gen_random_uuid();
BEGIN
  -- The Owned Stage is the second Stage and the Finished Stage the last, as the glossary defaults say.
  INSERT INTO workflows (id, owner_id, name, owned_stage_id, finished_stage_id, starter)
  VALUES (new_workflow_id, NEW.id, 'Starter', stage_ids[2], stage_ids[array_length(stage_ids, 1)], true);
  INSERT INTO stages (id, owner_id, workflow_id, name, position, colour)
  SELECT stage_ids[i], NEW.id, new_workflow_id, stage_names[i], i - 1, stage_colours[i]
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
  FOR t IN SELECT unnest(ARRAY['workflows', 'stages', 'collections', 'units', 'stage_changes', 'unit_tags', 'photos', 'splits', 'merges', 'paints'])
    EXCEPT SELECT tablename FROM pg_publication_tables WHERE pubname = 'powersync'
  LOOP
    EXECUTE format('ALTER PUBLICATION powersync ADD TABLE %I', t);
  END LOOP;
END \$\$;
''';

/// The password reset email. It carries a code to type into the app rather than a link, so the app needs no deep
/// links. GoTrue fills in the code.
const recoveryEmail = '''
<h2>Reset your Mini Vault password</h2>
<p>Enter this code in the app to choose a new password:</p>
<p style="font-size: 24px"><strong>{{ .Token }}</strong></p>
<p>If you didn't ask for this, you can ignore this email.</p>
''';

String _quote(String s) => "'${s.replaceAll("'", "''")}'";

/// `POST /upload` with `{"operations": [CrudEntry.toJson(), ...]}` and the user's GoTrue access token.
/// Applies the operations in one transaction. Answers 401 for a bad token, 403 if any operation touches
/// or points at another user's row, 409 for deleting a Workflow a Collection uses or a Stage that holds Units,
/// a Split that would leave its Unit under 1 model, or a Merge of Units that no longer match, 422 for an invalid
/// operation (including a reference to a missing row, or a PATCH or DELETE of an append-only Stage Change) or a batch
/// that leaves a Workflow invalid or a Unit at a Stage outside its Collection's Workflow
/// (nothing is written in those cases), and 204 on success.
/// Conflicts are the latest write wins per field, and deletes win: a PATCH to a deleted row is ignored.
/// Deleting a Collection deletes all its Units, including ones the client never saw.
///
/// `/photos/<file id>` stores and serves the user's photo files, kept in [dir]; see [photoRequest].
///
/// `DELETE /account` deletes the user's account: every row they own and their GoTrue user, in one transaction,
/// then their photo files. Answers 204. The app asks the user to confirm first.
///
/// A token of a deleted account is rejected (401) by all of these, though it has not expired.
///
/// `GET /health` answers 200 if Postgres answers `SELECT 1`, otherwise 503 (the deploy polls it).
///
/// `GET /email/recovery` answers [recoveryEmail], GoTrue's password reset email template (it only loads templates
/// over HTTP).
Handler writeApi(
  Pool<void> db,
  Directory dir, {
  required String jwtSecret,
}) => (request) async {
  final photo = switch (request.url.pathSegments) {
    ['photos', final id] => id,
    _ => null,
  };
  if (request.url.path == 'health' && request.method == 'GET') {
    try {
      await db.execute('SELECT 1').timeout(const Duration(seconds: 5));
      return Response.ok(null);
    } catch (_) {
      return Response(503);
    }
  }
  if (request.url.path == 'email/recovery' && request.method == 'GET') {
    return Response.ok(recoveryEmail, headers: {'content-type': 'text/html'});
  }
  final account = request.url.path == 'account';
  if (request.url.path != 'upload' && photo == null && !account) {
    return Response.notFound(null);
  }
  if (photo == null && request.method != (account ? 'DELETE' : 'POST')) {
    return Response(405);
  }

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
  final user = await db.execute(
    r'SELECT FROM auth.users WHERE id = $1::uuid',
    parameters: [owner],
  );
  if (user.isEmpty) return _error(401, 'The account no longer exists');
  if (account) {
    await db.runTx((tx) async {
      for (final table in _writable.keys) {
        await tx.execute(
          'DELETE FROM $table WHERE owner_id = \$1::uuid',
          parameters: [owner],
        );
      }
      // GoTrue's sessions, refresh tokens and identities go with the user by foreign-key cascade.
      await tx.execute(
        r'DELETE FROM auth.users WHERE id = $1::uuid',
        parameters: [owner],
      );
    });
    await deleteAllPhotos(dir, owner);
    return Response(204);
  }
  if (photo != null) {
    return photoRequest(db, dir, owner, photo, request);
  }

  final List<Map<String, Object?>> operations;
  try {
    final body = jsonDecode(await request.readAsString()) as Map;
    operations = [
      for (final op in body['operations'] as List) op as Map<String, Object?>,
    ];
  } catch (_) {
    return _error(400, 'Expected {"operations": [...]}');
  }

  try {
    final unlinked = <String>{};
    await db.runTx((tx) async {
      final touched = _Touched();
      final counted = <String>{};
      for (final op in operations) {
        await _apply(tx, owner, op, touched, unlinked, counted);
      }
      await _checkWorkflows(tx, touched.workflows);
      await _checkUnitStages(tx, touched);
    });
    await deleteUnreferencedPhotos(db, dir, owner, unlinked);
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

/// The rows a batch may have changed, to check once the whole batch is applied.
class _Touched {
  final workflows = <String>{};
  final collections = <String>{};
  final units = <String>{};
  final stageChanges = <String>{};
}

/// Applies [op], adding what it may have changed to [touched].
/// Adds the photo files of the Photo rows it deletes to [unlinked], to delete once no row points at them.
/// [counted] holds the Units whose count a Split or Merge earlier in the batch changed by a delta: the absolute
/// model_count the app uploads for them in the same batch (its local view) is ignored.
Future<void> _apply(
  TxSession tx,
  String owner,
  Map<String, Object?> op,
  _Touched touched,
  Set<String> unlinked,
  Set<String> counted,
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
  for (final column in ['name', 'brand', 'range']) {
    if (data[column] case final name?) {
      try {
        data[column] = validName(name as String);
      } on ArgumentError catch (e) {
        throw _Rejected(422, '$column ${e.message}');
      }
    }
  }
  if (data.containsKey('game_system')) {
    final gameSystem = data['game_system'];
    if (gameSystem is! String?) {
      throw _Rejected(422, 'A Game System must be text, not $gameSystem');
    }
    data['game_system'] = validGameSystem(gameSystem);
  }
  final colour = data['colour'];
  if (data.containsKey('colour') &&
      (colour is! String || !stageColourFormat.hasMatch(colour))) {
    throw _Rejected(422, 'A Stage colour must be #RRGGBB, not $colour');
  }
  if (table == 'units' && op['op'] == 'PATCH' && counted.contains(id)) {
    data.remove('model_count');
  }

  final existing = await tx.execute(
    'SELECT owner_id::text FROM $table WHERE id = \$1::uuid FOR UPDATE',
    parameters: [id],
  );
  if (existing.isNotEmpty && existing.first.first != owner) {
    throw _Rejected(403, 'Not your row: $table $id');
  }
  if (table == 'stage_changes') {
    if (op['op'] != 'PUT') {
      throw _Rejected(422, 'Stage Changes are append-only');
    }
    // A repeated upload of a Stage Change already stored (a retry) changes nothing.
    if (existing.isNotEmpty) return;
  }
  if (table == 'photos') {
    if (op['op'] == 'PATCH') throw _Rejected(422, 'Photos cannot be edited');
    // A Photo never changes, so a repeated upload (a retry) changes nothing.
    if (op['op'] == 'PUT' && existing.isNotEmpty) return;
  }
  if (table == 'splits' || table == 'merges') {
    if (op['op'] != 'PUT') throw _Rejected(422, '$table are append-only');
    if (data['unit_id'] case final String unitId) counted.add(unitId);
    // A retry: the delta was applied when it was first stored.
    if (existing.isNotEmpty) return;
    // Locks both Units in id order before anything reads them, so concurrent Splits and Merges of a Unit apply
    // one after the other, each to the count the previous one left, without deadlocking.
    await tx.execute(
      r'SELECT FROM units WHERE id = ANY($1::uuid[]) ORDER BY id FOR UPDATE',
      parameters: [
        TypedValue(Type.textArray, [
          for (final c in ['unit_id', 'new_unit_id', 'merged_unit_id'])
            if (data[c] case final String id) id,
        ]),
      ],
    );
  }

  // Skipped for a PATCH to a deleted row, which is ignored anyway (deletes win).
  // FOR SHARE holds off a concurrent delete of the referenced row until this batch commits.
  if (existing.isNotEmpty || op['op'] == 'PUT') {
    // A null reference (a Unit's initial Stage Change has no from-Stage) points at nothing; NOT NULL columns reject it.
    for (final column in data.keys.where(
      (c) => _references.containsKey(c) && data[c] != null,
    )) {
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
  if (table == 'unit_tags') _checkTag(op['op'], id, data);
  if (op['op'] == 'DELETE' && (table == 'photos' || table == 'units')) {
    unlinked.addAll([
      for (final row in await tx.execute(
        'SELECT file_id::text FROM photos WHERE ${table == 'units' ? 'unit_id' : 'id'} = \$1::uuid AND owner_id = \$2::uuid',
        parameters: [id, owner],
      ))
        row.first as String,
    ]);
  }
  // Deleting a Collection deletes its Units (their Photos first, to collect the files; Stage Changes and Tags go by
  // foreign-key cascade), including any
  // the client didn't know of: another device may have added one meanwhile, and deletes win. The FOR UPDATE above
  // waits for such a batch, which holds the Collection FOR SHARE, so its Unit is seen here; one arriving later is
  // rejected, as its Collection no longer exists.
  if (op['op'] == 'DELETE' && table == 'collections') {
    unlinked.addAll([
      for (final row in await tx.execute(
        r'''DELETE FROM photos p USING units u WHERE p.unit_id = u.id AND u.collection_id = $1::uuid
          AND u.owner_id = $2::uuid RETURNING p.file_id::text''',
        parameters: [id, owner],
      ))
        row.first as String,
    ]);
    await tx.execute(
      r'DELETE FROM units WHERE collection_id = $1::uuid AND owner_id = $2::uuid',
      parameters: [id, owner],
    );
  }
  touched.workflows.addAll({
    if (table == 'workflows') id,
    if (table == 'stages') ...[
      for (final row in await tx.execute(
        'SELECT workflow_id::text FROM stages WHERE id = \$1::uuid',
        parameters: [id],
      ))
        row.first as String,
      if (data['workflow_id'] case final String workflowId) workflowId,
    ],
  });
  if (table == 'collections' && data.containsKey('workflow_id')) {
    touched.collections.add(id);
  }

  // Column names come from _writable, never from the payload, so interpolating them is safe.
  final columns = data.keys.toList();
  final values = [id, owner, ...data.values];
  String param(int i, String type) => '\$${i + 3}::$type';
  final sets = [
    for (final (i, c) in columns.indexed) '$c = ${param(i, types[c]!)}',
  ];

  switch (op['op']) {
    // The same Tag added again, e.g. from another device: the first-entered casing stays.
    case 'PUT' when table == 'unit_tags' && existing.isNotEmpty:
      break;
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

  if (table == 'splits') await _split(tx, data);
  if (table == 'merges') await _merge(tx, owner, data, unlinked);

  if (table == 'photos' && op['op'] == 'PUT') {
    // FOR UPDATE on the Unit makes concurrent batches adding Photos to it count one after the other.
    await tx.execute(
      'SELECT FROM units WHERE id = \$1::uuid FOR UPDATE',
      parameters: [data['unit_id']],
    );
    final [[count]] = await tx.execute(
      'SELECT count(*) FROM photos WHERE unit_id = \$1::uuid',
      parameters: [data['unit_id']],
    );
    if ((count as int) > Vault.maxPhotos) {
      throw _Rejected(422, 'A Unit can have at most ${Vault.maxPhotos} photos');
    }
  }

  // units.stage_id is re-derived from the latest Stage Change (device timestamp, then id) after every write to a Unit or its Stage Changes, so upload order and a client's stale stage_id never decide it.
  final unitId = switch (table) {
    'units' => id,
    'stage_changes' => data['unit_id'],
    _ => null,
  };
  if (unitId is String) {
    await tx.execute(
      r'''UPDATE units u SET stage_id = latest.to_stage_id
        FROM (SELECT to_stage_id FROM stage_changes WHERE unit_id = $1::uuid
          ORDER BY happened_at DESC, id DESC LIMIT 1) latest
        WHERE u.id = $1::uuid AND u.stage_id <> latest.to_stage_id''',
      parameters: [unitId],
    );
    touched.units.add(unitId);
  }
  if (table == 'stage_changes') touched.stageChanges.add(id);
}

/// Rejects the batch if it leaves a Unit at a Stage outside its Collection's Workflow, or appended a Stage Change to
/// such a Stage. Checked after the whole batch, not per operation: switching a Collection to another Workflow changes
/// the Collection and moves its Units, and no order of those writes is valid in between. It also covers a Unit the
/// batch doesn't mention, such as one another device added to the Collection meanwhile.
Future<void> _checkUnitStages(TxSession tx, _Touched touched) async {
  if (touched.units.isEmpty &&
      touched.collections.isEmpty &&
      touched.stageChanges.isEmpty) {
    return;
  }
  final outside = await tx.execute(
    r'''SELECT 'Stage Change ' || sc.id || ': its to-Stage' FROM stage_changes sc
        JOIN units u ON u.id = sc.unit_id JOIN collections c ON c.id = u.collection_id
        JOIN stages s ON s.id = sc.to_stage_id
      WHERE sc.id::text = ANY($3) AND s.workflow_id <> c.workflow_id
      UNION ALL
      SELECT 'Unit ' || u.id || ': its Stage' FROM units u
        JOIN collections c ON c.id = u.collection_id JOIN stages s ON s.id = u.stage_id
      WHERE (u.id::text = ANY($1) OR u.collection_id::text = ANY($2)) AND s.workflow_id <> c.workflow_id
      LIMIT 1''',
    parameters: [
      for (final ids in [
        touched.units,
        touched.collections,
        touched.stageChanges,
      ])
        TypedValue(Type.textArray, ids.toList()),
    ],
  );
  if (outside.isNotEmpty) {
    throw _Rejected(
      422,
      "${outside.first.first} is not in its Collection's Workflow",
    );
  }
}

/// Applies a newly stored Split as a delta: its models come off its Unit's count as it is now, so concurrent Splits
/// add up (10 − 4 − 3 leaves 3). Rejected (409) if that would leave fewer than 1 model: a Split never takes all.
Future<void> _split(TxSession tx, Map<String, Object?> data) async {
  final rows = await tx.execute(
    r'''SELECT a.model_count - $3::int FROM units a JOIN units b ON b.collection_id = a.collection_id AND b.id <> a.id
      WHERE a.id = $1::uuid AND b.id = $2::uuid''',
    parameters: [data['unit_id'], data['new_unit_id'], data['model_count']],
  );
  if (rows.isEmpty) {
    throw _Rejected(422, 'A Split makes another Unit in the same Collection');
  }
  final left = rows.first.first as int;
  if (left < 1) {
    throw _Rejected(
      409,
      'Split of ${data['model_count']} would leave Unit ${data['unit_id']} with $left models',
    );
  }
  await tx.execute(
    r'UPDATE units SET model_count = $2::int WHERE id = $1::uuid',
    parameters: [data['unit_id'], left],
  );
}

/// Applies a newly stored Merge: adds the merged Unit's count as it is now to the Unit and deletes the merged Unit
/// (its Stage Changes, Tags and Photos go with it; the app's batch copies them over). Rejected (409) unless both
/// still share Collection, name and Stage, e.g. after a concurrent move; a second Merge of a Unit already merged
/// away is rejected because the Unit no longer exists (422).
Future<void> _merge(
  TxSession tx,
  String owner,
  Map<String, Object?> data,
  Set<String> unlinked,
) async {
  final rows = await tx.execute(
    r'''SELECT b.model_count FROM units a JOIN units b ON b.collection_id = a.collection_id
        AND b.name = a.name AND b.stage_id = a.stage_id AND b.id <> a.id
      WHERE a.id = $1::uuid AND b.id = $2::uuid''',
    parameters: [data['unit_id'], data['merged_unit_id']],
  );
  if (rows.isEmpty) {
    throw _Rejected(
      409,
      'Only Units in the same Collection, with the same name, at the same Stage can be Merged',
    );
  }
  await tx.execute(
    r'UPDATE units SET model_count = model_count + $2::int WHERE id = $1::uuid',
    parameters: [data['unit_id'], rows.first.first],
  );
  unlinked.addAll([
    for (final row in await tx.execute(
      r'SELECT file_id::text FROM photos WHERE unit_id = $1::uuid AND owner_id = $2::uuid',
      parameters: [data['merged_unit_id'], owner],
    ))
      row.first as String,
  ]);
  await tx.execute(
    r'DELETE FROM units WHERE id = $1::uuid',
    parameters: [data['merged_unit_id']],
  );
}

/// A Tag is never edited, only added and removed, and its id must be [tagId] of its Unit and name.
void _checkTag(Object? op, String id, Map<String, Object?> data) {
  if (op == 'PATCH') throw _Rejected(422, 'Tags cannot be edited');
  if (op != 'PUT') return;
  if (data case {'unit_id': final String unitId, 'name': final String name}) {
    try {
      if (tagId(unitId, name) == id) return;
    } on FormatException {
      // Falls through to the rejection.
    }
  }
  throw _Rejected(422, 'Tag $id must have the id of its unit_id and name');
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
