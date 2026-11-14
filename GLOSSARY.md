# Mini Vault

Tracks where each part of a tabletop miniature collection stands on its way from wishlist to finished, regardless of which game system the models belong to.

## Language

**Collection**:
A named set of Units owned by one person, all progressing through the same Workflow. Has an optional free-text description and any number of Paint Schemes.
_Avoid_: Army (for this meaning)

**Game System**:
The tabletop game a Collection belongs to (e.g. Warhammer 40k, D&D), named freely by the person; a Collection has at most one. Collections whose Game System is written alike, ignoring case, share it.
_Avoid_: System, game, franchise, category

**Unit**:
All the models in a Collection that a person tracks under one name (e.g. "Intercessors"); its models may be spread across Stages. Not necessarily a unit in game rules: it is whatever a person chose to name alike. A Unit has notes, Tags and photos and may use Paints, each with an optional note on where or how (e.g. "armour base"); renaming the Unit keeps them, and its Paints stay with the name even while it has no models.
_Avoid_: Squad, group, kit, box, entry

**Category**:
A named group of Units within one Collection (e.g. Heroes, Core, Support), defined freely per Collection and kept in the order the person chooses. No two Categories of one Collection share a name, ignoring case. A Unit is in at most one Category; Units in none are Uncategorised. Deleting a Category keeps its Units, which become Uncategorised. Within a Collection, Units also keep a person-chosen order.
_Avoid_: Tag (a Unit has many Tags but one Category), role, section

**Batch**:
The models of one Unit that are at the same Stage; a Unit has at most one Batch per Stage. People rarely see the word: they see "models at a Stage".
_Avoid_: Unit (for this meaning), lot, group

**Workflow**:
An ordered, linear list of Stages, reusable across Collections; changing it changes it for every Collection that uses it.
_Avoid_: Pipeline, process, status list

**Stage**:
One step in a Workflow (e.g. Wishlist, Unassembled, Primed). Each model is at exactly one Stage at a time and may move to any other Stage in its Workflow, forward or back.
_Avoid_: Status, state, step

**Owned Stage**:
The Stage in a Workflow from which a Unit's models count as part of the collection; models at earlier Stages (e.g. Wishlist) are wanted but not yet owned. By default the Workflow's second Stage.

**Finished Stage**:
The Stage in a Workflow from which a Unit's models count as finished; models at it or any later Stage are finished. By default the Workflow's last Stage.
_Avoid_: Done, complete

**Progress**:
How far a Collection, or several Collections together, has come: how many models are wanted, owned and finished, and how many owned models sit at each Stage. Finished models are always also owned; wanted models are never owned.
_Avoid_: Stats, statistics, completion

**Stage Change**:
A record that some of a Unit's models moved from one Stage to another, how many, and when. A Unit's Stage Changes form its history.
_Avoid_: Event, log entry, transition

**Split**:
Moving only some of a Unit's models at one Stage to another Stage, which starts a new Batch there unless one exists.

**Merge**:
Combining a Unit's models that arrive at a Stage with its Batch already there. Always automatic, so a Unit never has two Batches at one Stage.

**Army List**:
A list of game-rules units made in another app (e.g. the Warhammer 40k app, Army Forge) for one faction of one Game System. Importing it adds each entry's models, all at one chosen Stage, to the Unit of that name in a single Collection, creating the Unit if needed; it never removes models already there.
_Avoid_: Roster, list, army

**Tag**:
A free-form label on a Unit, used for faction or any other grouping below the Collection. Game Systems belong to Collections, not Tags.
_Avoid_: Category, label, faction field

**Paint**:
One product from one manufacturer, named by brand, an optional range, and name (e.g. Citadel / Base / Macragge Blue, or AP / Greedy Gold), in a person's paint library independent of any Collection. Each Paint is either owned or wanted; the wanted ones are the shopping list. Washes, contrast paints, primers and technicals are Paints too. Brands written alike, ignoring case, are the same brand, and no two Paints share brand, range and name; a missing range counts as one more range.
_Avoid_: Color, colour, pot, swatch

**Technique**:
How paint goes on in one part of a Paint Scheme (e.g. Basecoat, Wash, Drybrush, Airbrush), named freely by the person. Techniques written alike, ignoring case, are the same Technique.
_Avoid_: Method, style

**Paint Scheme**:
A named, ordered recipe for painting one part of a Collection's models (e.g. "Armour", "Bases"); a Collection has any number. It belongs to the Collection, not to any Unit, and goes when the Collection is deleted.
_Avoid_: Recipe, guide

**Scheme Step**:
One numbered entry in a Paint Scheme: any number of Paints (several means mixed), an optional Technique and an optional note, at least one of the three. Deleting a Paint takes it out of every Scheme Step but keeps the Step.
_Avoid_: Step (a Stage is a step in a Workflow), layer

**Theme**:
The named look of the app on one device (e.g. Grimdark, Fantasy): its colours and heading font. Every Theme comes in a light and a dark version; which one shows is a separate choice. Stage colours belong to the Stage and are not changed by the Theme.
_Avoid_: Skin, style, preset

**Brightness**:
Whether a device shows its Theme's light or dark version: Light, Dark, or System (follow the device's own setting, the default). Chosen per device, like the Theme.
_Avoid_: Mode, appearance, dark mode (for the setting itself)
