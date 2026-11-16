FROM rust:1-bookworm AS build

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

# Runtime: same Debian release as the build stage (glibc match), plus liblzma5 which the
# binary links against and which the distroless base lacks.
FROM debian:bookworm-slim

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get -y install --no-install-recommends ca-certificates tzdata liblzma5 libssl3 && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# copy built executable
COPY --from=build /app/target/release/microbin /usr/bin/microbin

# copy data directory skeleton with nonroot ownership
RUN useradd --uid 65532 --user-group --no-create-home --shell /usr/sbin/nologin nonroot || true
COPY --from=build --chown=65532:65532 /app/microbin_data /app/microbin_data

USER 65532:65532

# Data lives on a Railway volume mounted at MICROBIN_DATA_DIR (VOLUME is not supported by Railway).

# Expose webport used for the webserver to the docker runtime
EXPOSE 8080

ENTRYPOINT ["/usr/bin/microbin"]
