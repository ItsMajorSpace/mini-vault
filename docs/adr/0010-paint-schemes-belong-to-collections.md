# Paint Schemes belong to Collections, apart from a Unit's Paints

People describe how they paint an army once, as ordered recipes ("Armour: 1. prime, 2. basecoat Macragge Blue, 3. wash..."), not per Unit. So a Collection has named Paint Schemes of ordered Scheme Steps, each with Paints, a Technique and a note. This does not reverse ADR 0007: a Unit still records the Paints it uses against its Collection and name, and Units do not link to Paint Schemes.

## Considered Options

- **Plain Collection notes only**: cheapest, but loses the Paint links (so deleting or renaming a Paint can't follow) and the order people asked for. Kept anyway as a Collection's free-text description.
- **One scheme per Collection with a "part" per step**: fewer screens, but reordering mixes armour and base steps in one list.
- **Units link to Paint Schemes**: rejected for now, as in ADR 0007, until someone asks.

## Consequences

Deleting a Paint removes it from every Scheme Step and Unit, keeping the Steps. Deleting a Collection deletes its Paint Schemes. Copying a scheme to another Collection is a later addition.
