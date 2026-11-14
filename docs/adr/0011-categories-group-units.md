# Categories group a Collection's Units, one per Unit

People think of an army in parts ("Heroes, Core, Support") and want its Units listed that way, not A–Z. So a Collection has Categories, named freely and kept in the order the person chooses, and a Unit is in at most one; the rest are Uncategorised. Categories are synced like the rest of a Collection.

A Collection's Categories are rows of `categories` (collection_id, name, position), ordered by (position, id) as Stages are. A Unit's Category is a `squad_categories` row keyed like its notes: its id is the Unit's `unitId`, so it stays with the Unit's name (ADR 0008) and two devices placing the same Unit write one row, the latest change winning. A missing row, or a null `category_id`, is Uncategorised. Both tables are new and only added to, so app versions without Categories keep working (ADR 0006).

## Considered Options

- **Tags as Categories**: rejected; a Unit has many Tags, and Tags have no order and belong to no Collection.
- **A category_id column on `units`**: rejected; `units` holds Batches, and every Batch of a Unit would have to agree.
- **Unique names enforced by the server**: rejected; two devices may add the same name offline and one would be refused. The app picks the existing Category, ignoring case, when a name is typed again.

## Consequences

Adding models to an existing Unit never moves it, and an Army List import leaves new Units Uncategorised. Renaming a Unit carries its Category, unless onto an existing Unit, which keeps its own. Deleting a Category leaves its Units Uncategorised (`ON DELETE SET NULL`); deleting a Collection deletes its Categories. The order of Units inside a Category stays alphabetical until Units get their own order.
