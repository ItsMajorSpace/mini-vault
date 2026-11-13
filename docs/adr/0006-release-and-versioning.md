# A release is an app release; the server is versioned by commit

Only the app gets a human-chosen version. A release is cut with `gh release create vX.Y.Z --generate-notes` on `main` (`--prerelease` for `-rc.N` tags), and CI attaches the release-signed APK to that GitHub Release. The server keeps deploying every green commit on `main` (ADR 0005); release tags only add semver image tags to roll back to. Versions matter for what people install and keep running for weeks, and that is the app; giving the server its own version would mean either giving up continuous deploy or tracking two version streams.

The tag is the only source of the version: CI passes it as `--build-name` and `github.run_number` as `--build-number`, which only ever grows, as Android requires. `pubspec.yaml` stays at `0.0.0-dev+0`, so a local build is visibly a dev build and there is no file to forget to bump.

- **MAJOR**: raises the minimum supported app version, forcing older apps to update. While on `0.x`, a breaking change bumps MINOR instead; `1.0.0` is the first store release.
- **MINOR**: new features.
- **PATCH**: fixes only.

## Considered Options

- **One product version for app and server, server deploys only on tags**: loses continuous deploy for no gain to anyone installing the app.
- **Separate `app-v*` / `server-v*` versions**: two streams to keep straight for a single-developer project.
- **release-please / semantic-release**: needs conventional-commit discipline and a bot; squash-merged PR titles already make good release notes.
- **Version bumped in `pubspec.yaml` by PR, checked against the tag**: an extra step per release and a way to get it wrong.

## Consequences

The server must never break an app version that is still supported. The app is offline-first and old APKs stay installed for months while the server changes daily, so schema and API changes go expand, then contract: add the new shape, remove the old one only once no supported app needs it. A minimum supported app version check (server rejects older apps, app asks the user to update) is added the first time a change cannot stay backward compatible; that release is a MAJOR bump.

The APK is signed with a release keystore from the first build anyone else installs, kept as a GitHub secret and backed up offline: Android will not install a build signed with a different key over an existing one, so changing keys later means uninstalling and losing unsynced local data. On Google Play this key becomes the upload key under Play App Signing.
