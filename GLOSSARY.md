# Mini Vault

Tracks where each part of a tabletop miniature collection stands on its way from wishlist to finished, regardless of which game system the models belong to.

## Language

**Collection**:
A named set of Units owned by one person, all progressing through the same Workflow.

**Unit**:
A number of models tracked together because they are at the same Stage; it belongs to exactly one Collection. Not the same as a unit in game rules: one in-game unit may be several Units here while its models are at different Stages.
_Avoid_: Batch, entry, kit, box

**Squad**:
All the Units in a Collection that share a name; its models are spread across Stages. Not a game-rules unit either: it is whatever a person chose to name alike.
_Avoid_: Group, line, entry

**Workflow**:
An ordered, linear list of Stages, reusable across Collections; changing it changes it for every Collection that uses it.
_Avoid_: Pipeline, process, status list

**Stage**:
One step in a Workflow (e.g. Wishlist, Unassembled, Primed). Each Unit is at exactly one Stage at a time and may move to any other Stage in its Workflow, forward or back.
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
A record that a Unit moved from one Stage to another, and when. A Unit's Stage Changes form its history.
_Avoid_: Event, log entry, transition

**Split**:
Moving only some of a Unit's models to another Stage, which creates a new Unit for those models.

**Merge**:
Combining two Units that share a Collection, name and Stage into one Unit. Happens automatically when models are moved onto a Stage where such a Unit already exists; Units that already share a Stage are Merged only by explicit choice.

**Tag**:
A free-form label on a Unit, used for game system, faction or any other grouping. Mini Vault knows nothing about specific game systems; Tags are how a person expresses them.
_Avoid_: Category, label, faction field
