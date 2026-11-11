set shell := ["bash", "-cu"]

collector:
    cargo build --release --locked
    install -Dm755 target/release/noctalia-stats-collector stats/bin/.collector-new
    mv stats/bin/.collector-new stats/bin/noctalia-stats-collector

# Exercise the compiled collector protocol and complete service/UI lifecycles.
check: collector
    uv run python -m unittest discover -s tests -v
    luau-analyze stats
    noctalia plugins lint stats
    cargo clippy --locked -- -D warnings

format:
    cargo fmt
    stylua stats tests/scenarios.luau

format-check:
    cargo fmt --check
    stylua --check stats tests/scenarios.luau

reload: collector
    noctalia plugins lint stats
    noctalia msg config-reload

register: collector
    noctalia msg plugins source add noctalia-stats path "{{justfile_directory()}}"
    noctalia msg config-reload

lint:
    noctalia plugins lint stats
