# A Unit's models at one Stage always form one Batch

ADR 0004 merged models automatically when they arrived at a Stage, but kept an explicit Merge for two Batches that already shared a Stage (e.g. after concurrent moves on two devices). Now that Batches are hidden (ADR 0008), nobody can see that two exist, so that case is merged automatically too, and the Merge actions, the "Which Unit?" choice and the recount restriction go away.

## Consequences

Supersedes the explicit-Merge part of ADR 0004. Two Batches that meet through sync, not through a move, must still be merged by the app.
