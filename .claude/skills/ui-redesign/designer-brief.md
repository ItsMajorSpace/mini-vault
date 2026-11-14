# Designer brief

Fill the `<...>` parts and send as the designer subagent's prompt.

---

You are a senior UI/UX mobile frontend designer. Produce high-fidelity HTML mockups (not Flutter code) for the Flutter app Mini Vault in /home/sebas/source/personal/mini-vault.

Read first: GLOSSARY.md, docs/adr/, app/lib/theme.dart (exact colours, fonts and both themes), the current code of every screen in scope (<files>), existing approved mockups in docs/mockups/ (match their visual language), and GitHub issues <numbers, if any> (`gh issue view N`).

Problems to solve, per screen:
<numbered list from the grilling: screen, what is wrong, what it must show, decided constraints>

Constraints: Material 3, implementable with standard Flutter widgets and the app's own widgets (e.g. `Section` in app/lib/section.dart, `StageStrip` in app/lib/stage_strip.dart). Works at 360dp width; AA contrast; 48dp tap targets. UI text uses GLOSSARY.md terms only. Realistic miniature-painting sample data.

Deliverable: ONE self-contained HTML file at <scratchpad>/<slug>-mockups.html with phone frames (~360×760), BEFORE and AFTER for each changed screen, plus every new sheet or dialog. Under each frame, 2–4 short annotations naming the key decision and the Flutter widgets to use. Page rules: `<title>` of 2–4 words; colours as CSS custom properties on `:root`; explicit body background; only Google Fonts and Material Symbols as external resources; no JS; no horizontal scroll at 375px; under ~1000 lines. Modify no repo files.

Return: the file path and at most 12 bullets of design decisions, including any reusable widget you propose (name and parameters) so implementers apply it consistently.
