# Categories group a Collection's Units, one per Unit

People think of an army in parts ("Heroes, Core, Support") and want its Units listed that way, not A–Z. So a Collection has Categories, named freely and kept in the order the person chooses, and a Unit is in at most one; the rest are Uncategorised. Categories are synced like the rest of a Collection.

A Collection's Categories are rows of `categories` (collection_id, name, position), ordered by (position, id) as Stages are. A Unit's Category is a `squad_categories` row keyed like its notes: its id is the Unit's `unitId`, so it stays with the Unit's name (ADR 0008) and two devices placing the same Unit write one row, the latest change winning. A missing row, or a null `category_id`, is Uncategorised. Both tables are new and only added to, so app versions without Categories keep working (ADR 0006).

## Considered Options

- **Tags as Categories**: rejected; a Unit has many Tags, and Tags have no order and belong to no Collection.
- **A category_id column on `units`**: rejected; `units` holds Batches, and every Batch of a Unit would have to agree.
- **Unique names enforced by the server**: rejected; two devices may add the same name offline and one would be refused. The app picks the existing Category, ignoring case, when a name is typed again.

## Consequences

Adding models to an existing Unit never moves it, and an Army List import leaves new Units Uncategorised. Renaming a Unit carries its Category, unless onto an existing Unit, which keeps its own. Deleting a Category leaves its Units Uncategorised (`ON DELETE SET NULL`); deleting a Collection deletes its Categories.

## Unit order (#158)

Units also keep a person-chosen order inside their Category: a nullable `position` on the Unit's `squad_categories` row, so a drop that moves a Unit into another Category writes its Category and place in one row, and a rename carries both. Units are ordered by (position, name), a Unit without a position first: Units from before Unit order start alphabetical, and app versions before it, which never write the column, leave it as it is. A new Unit, or one put in another Category, goes last there; Uncategorised Units get a row too, with a null `category_id`. A reorder renumbers only the target Category and writes only the positions that change, as Stage reorder does; concurrent reorders on two devices can merge into a mix of both. The column was added with `ADD COLUMN IF NOT EXISTS` (ADR 0006).
