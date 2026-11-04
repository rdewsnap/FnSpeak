# syntax=docker/dockerfile:1
# Build from the repository root:
#   docker build -f deploy/Dockerfile -t fnspeak-server .

FROM rust:1-bookworm AS build
WORKDIR /src
# The whole workspace has to be present for Cargo to resolve it, but only
# fnspeak-server is compiled. rust-toolchain.toml is left out so the
# image's toolchain is used as is.
COPY Cargo.toml Cargo.lock ./
COPY crates crates
COPY prompts prompts
RUN --mount=type=cache,target=/usr/local/cargo/registry \
    --mount=type=cache,target=/src/target \
    cargo build --release --locked -p fnspeak-server --features postgres \
    && cp target/release/fnspeak-server /fnspeak-server
# Writable home for the SQLite file when no Postgres URL is given.
RUN mkdir -p /data

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /fnspeak-server /usr/local/bin/fnspeak-server
COPY --from=build --chown=nonroot:nonroot /data /data
ENV FNSPEAK_BIND=0.0.0.0:8080 \
    FNSPEAK_DATABASE_URL=sqlite:///data/fnspeak.db \
    FNSPEAK_LOG_FORMAT=json
VOLUME /data
EXPOSE 8080
USER nonroot
ENTRYPOINT ["/usr/local/bin/fnspeak-server"]
