# Implementer brief

Send as the implementation subagent's prompt, prefixed with the issue number and the current hand-off notes.

---

Implement GitHub issue #<N> in /home/sebas/source/personal/mini-vault. Hand-off notes from earlier tickets:

<handoff.md contents>

Process:

0. `git fetch && git switch -c <N>-<slug> origin/main`. Read CLAUDE.md, GLOSSARY.md, the issue (`gh issue view <N>`), and the approved mockup it names in docs/mockups/ (the notes under each frame name the Flutter widgets). Follow existing patterns and the commit style of `git log -5`. Keep the change minimal and keep domain rules as they are unless the issue says otherwise.
1. Test-first: widget/behaviour tests for every "Done when" item, against the real SQLite-backed Vault as existing app tests do (no mocks of our own code). Seed data BEFORE pumping the screen, or inside `tester.runAsync`: database writes from the test body after the screen is open deadlock.
2. Wrap every test command in `timeout 300` (e.g. `timeout 300 flutter test --timeout 120s test/x_test.dart`) and redirect long output to a file you then read. A run that hits the timeout is stuck: find and fix the cause.
3. Run everything .github/workflows/ci.yml runs: `flutter pub get`, `dart analyze`, `dart format --output=none --set-exit-if-changed .`, `dart test` where relevant, `flutter test` in app/. Run server/integration tests only if you touched server/ or domain_core/; they need Docker, so run them under `flock /tmp/claude-1000/mini-vault-stack.lock <command>` and finish with `docker compose down -v`.
4. Commit (message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), push, and open a PR titled "<summary> (#<N>)" whose body has `Closes #<N>`, a behaviour summary and the tests, ending with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`. Leave merging to the orchestrator.
5. Wait for CI (`gh pr checks --watch`) and fix failures until green.

Report in under 200 words: PR URL, CI status, what the tests cover, anything skipped, risky or different from the mockup, and a HAND-OFF section for the next implementer: new widgets/functions (file, name, API) to reuse, test keys and helpers, and gotchas.
