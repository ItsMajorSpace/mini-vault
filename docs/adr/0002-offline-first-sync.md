# Offline-first with background sync

Every change is saved to a local database on the device first and syncs to the server in the background; the app never waits on the network to record progress. Hobby time often happens without reliable connectivity (hobby shops, basements, travel), and the app supports multiple users with server-side accounts, so a server is needed but must not be in the critical path. Retrofitting offline support onto an online-only data layer later would mean rewriting it.
