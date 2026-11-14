# The release keystore is Play's app signing key, not its upload key

On Google Play the release keystore (ADR 0006) is uploaded as the app signing key under Play App Signing, and a separate, new key is the upload key. Android only installs an update signed with the same key as the installed app, so this keeps GitHub Release APKs and Play builds able to update each other: early testers who sideloaded an APK move to Play without uninstalling and losing unsynced local data, and APKs on GitHub Releases keep working after the Play launch.

## Considered Options

- **Keystore as upload key, Google generates the app signing key** (the Play default, and what ADR 0006 first assumed): Play installs and GitHub APKs are signed differently, so neither can update the other, and every sideloading tester would have to uninstall to switch.
- **Stop publishing APKs on GitHub Releases once on Play**: avoids the mismatch for new users but still strands existing sideloaded installs.

## Consequences

Once Play holds the key it cannot be taken back, and the offline backup of the keystore matters even more: it now signs every install from both channels. A lost upload key can be reset through Play support; a leaked app signing key cannot be rotated without Play's key upgrade, which only covers newer Android versions.
