# Flutter for all clients

We build every client (iOS and Android now, macOS/Windows/Linux later) from one Flutter codebase that compiles to native code, instead of writing a native UI for each platform. This is a solo hobby project, and separate SwiftUI/Compose/desktop UIs would multiply the work for every feature. Flutter was the most mature option across all five targets.

## Considered Options

- **Separate native UI per platform**: platform-perfect look and feel, but several codebases to maintain.
- **Kotlin Multiplatform + Compose Multiplatform**: strong on Android, younger on iOS, and its desktop version runs on the JVM.
- **.NET MAUI**: rejected because it doesn't support Linux.
