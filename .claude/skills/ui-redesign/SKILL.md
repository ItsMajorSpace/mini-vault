---
name: ui-redesign
description: Redesign app screens end to end: grill the goals, have a UI/UX designer subagent draw HTML mockups, turn approved mockups into tickets, then implement them one subagent per ticket. Use when the user wants a screen's layout or UX reworked, or asks for the designer agent or mockups.
---

# UI redesign

Four phases, each ending on a gate. Run them in order; the user approves at gates 1–3, and phase 4 runs unattended.

## 1. Grill

Run `/grill-with-docs` on the request. Settle at least: which screens are in scope, the concrete problems per screen, whether domain rules may change (default: UI only), and any user feedback or screenshots to honour.

**Done when** the user confirms shared understanding and GLOSSARY.md holds any new terms.

## 2. Mockups

Dispatch one `general-purpose` subagent as the designer, using [designer-brief.md](designer-brief.md). Keep its id: every revision goes to the same designer via SendMessage, so it keeps its context. Publish the HTML as an Artifact so the user can review it on any device; republish the same file after each revision.

**Done when** the user says the mockups are approved. Then copy the HTML to `docs/mockups/<slug>.html`.

## 3. Tickets

Split the approved design into vertical slices, one ticket per slice that can ship and be tested alone, ordered so each builds on the last. Each GitHub issue (see docs/agents/issue-tracker.md) carries: the mockup path and frame names, the behaviour as a "Done when" checklist, and "UI only, no domain changes" when that was decided. Link order with "Blocked by #N" and label `ready-for-agent`.

**Done when** the user approves the ticket list.

## 4. Implement

One implementation subagent per ticket, strictly sequential, using [implementer-brief.md](implementer-brief.md). Before the first dispatch, create an empty `handoff.md` in the scratchpad.

Per ticket:

1. Dispatch the implementer with the brief, the issue number, and the current contents of `handoff.md`.
2. While it runs, watch for stuck tests: any `flutter_tester` or `dart test` process older than 5 minutes is stuck. Kill it, tell the implementer the cause is a hang (usually database writes after the screen is pumped), and have it fix the cause.
3. When it reports a green PR: read the diff, confirm every "Done when" item has a test, squash-merge (`gh pr merge --squash --delete-branch`), and check the issue closed.
4. Append the implementer's HAND-OFF section to `handoff.md`.

If a usage limit stops work, schedule a wakeup after the reset and continue with the next unmerged ticket.

**Done when** every ticket is merged and `main`'s CI is green. Report a table of ticket → PR → what the user will see, then the caveats implementers flagged (known gaps, divergences from the mockup, what was never checked on a device).
