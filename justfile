set shell := ["bash", "-cu"]

# Exercise the collector script and complete service/UI lifecycles.
check:
    shellcheck stats/bin/noctalia-stats-collector
    uv run python -m unittest discover -s tests -v
    luau-analyze stats
    noctalia plugins lint stats

format:
    stylua stats tests

format-check:
    stylua --check stats tests

reload:
    noctalia plugins lint stats
    noctalia msg config-reload

register:
    noctalia msg plugins source add noctalia-stats path "{{justfile_directory()}}"
    noctalia msg config-reload

lint:
    noctalia plugins lint stats
