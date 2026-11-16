FROM rust:1 AS build

WORKDIR /app

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get -y install --no-install-recommends ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

COPY . .

# Infra patch: upstream picks paste IDs as random u16 with no uniqueness check, so a
# collision panics inside the SQLite insert and poisons the shared lock (every later
# upload then 502s). Use a wide random ID and let the lock survive a panic.
RUN sed -i 's/rand::thread_rng().gen::<u16>() as u64/rand::thread_rng().gen_range(1..=9_007_199_254_740_991u64)/' src/endpoints/create.rs && \
    grep -q 'gen_range(1..=9_007_199_254_740_991u64)' src/endpoints/create.rs && \
    find src -name '*.rs' -exec sed -i 's/\.lock()\.unwrap()/.lock().unwrap_or_else(|e| e.into_inner())/g' {} + && \
    grep -rq 'unwrap_or_else(|e| e.into_inner())' src

RUN CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release && \
    mkdir -p /app/microbin_data

# https://github.com/GoogleContainerTools/distroless
# nonroot user (uid:gid 65532:65532) is pre-defined in distroless images
FROM gcr.io/distroless/cc-debian12

WORKDIR /app

# copy time zone info from build stage
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo

# copy CA certificates from build stage
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# copy built executable
COPY --from=build /app/target/release/microbin /usr/bin/microbin

# copy data directory skeleton with nonroot ownership
COPY --from=build --chown=65532:65532 /app/microbin_data /app/microbin_data

USER 65532:65532

VOLUME ["/app/microbin_data"]

# Expose webport used for the webserver to the docker runtime
EXPOSE 8080

ENTRYPOINT ["/usr/bin/microbin"]
