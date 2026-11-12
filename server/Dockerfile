# Build from the repository root, since the write API depends on domain_core:
#   docker build -f server/Dockerfile .
FROM dart:3.14.0 AS build
WORKDIR /src
COPY pubspec.yaml pubspec.lock ./
COPY domain_core/pubspec.yaml domain_core/
COPY server/pubspec.yaml server/
# The workspace also lists the Flutter app, which the Dart image cannot resolve.
RUN sed -i '/^  - app$/d' pubspec.yaml && dart pub get
COPY domain_core domain_core
COPY server server
# shortcut: dart build (not compile exe) because domain_core's client-only deps have build hooks; it bundles SQLite libraries the server never loads. Move SqliteVaultStore into its own package if the image size matters.
RUN cd server && dart build cli -o /out

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/bundle/ /app/
ENTRYPOINT ["/app/bin/server"]
