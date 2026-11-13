# Unit is the named thing people track; Batch is its models at one Stage

People think in "my Intercessors", not in "the 3 Intercessors at Primed", yet the app called the per-Stage record a Unit and the named whole a Squad, and made people Split, Merge and pick between Units. So the named whole is now the **Unit** and the per-Stage record a **Batch**, which the screens rarely show. Notes, Tags and photos belong to the Unit, as Paints already do (ADR 0007); a Batch keeps only its Stage, its model count and its Stage Changes. Dart code uses the new names; the database keeps the old ones, because its tables are synced through PowerSync and renaming them would mean a migration on the server and every device for no gain to people.

## Consequences

- Table `units` holds Batches; a Unit is the rows sharing a Collection and name, and its Paints, notes, Tags and photos are the `squad_paints`, `squad_notes`, `squad_tags` and `squad_photos` rows for that name. Read the old table names through this mapping. `unit_tags`, `photos` and `units.notes` held them per Batch until #105 and stay only for app versions from before it.
- ADRs 0001–0007 use the old words: their "Unit" is a Batch and their "Squad" is a Unit.
