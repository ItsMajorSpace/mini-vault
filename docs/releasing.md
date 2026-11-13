# Releasing

A release is an app release; the server deploys every green commit on `main` regardless ([ADR 0006](adr/0006-release-and-versioning.md)).

## How to cut a release

From an up-to-date `main`:

```sh
gh release create vX.Y.Z --target main --generate-notes
gh release create vX.Y.Z-rc.N --target main --generate-notes --prerelease   # release candidate
```

This creates the tag, which runs CI. The tag is the app version; `pubspec.yaml` is never bumped. The `apk` job builds the release APK and attaches it to the Release as `mini-vault-vX.Y.Z.apk`. Pushing a bare tag also works: CI creates the Release if it is missing.

## Which number to bump

- **MAJOR**: raises the minimum supported app version, forcing older apps to update. While on `0.x`, a breaking change bumps MINOR instead; `1.0.0` is the first store release.
- **MINOR**: new features.
- **PATCH**: fixes only.

The server must never break an app version that is still supported: change schemas and APIs expand, then contract.
