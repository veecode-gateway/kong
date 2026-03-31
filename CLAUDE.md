# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Kong Gateway is an open-source API gateway built on OpenResty (Nginx + Lua). The codebase is primarily Lua with a Bazel build system.

## Build & Development

```bash
# Build development environment
make dev

# Activate virtual environment (required before running Kong or tests)
. bazel-bin/build/kong-dev-venv.sh

# Start supporting services (Postgres, Cassandra, Redis via Docker)
start_services

# Bootstrap database and start Kong
kong migrations bootstrap
kong start
```

Key build targets:

```bash
make build-kong          # Build Kong via Bazel
make build-openresty     # Build OpenResty
make install-dev-rocks   # Install dev dependencies (busted, luacheck, etc.)
make clean               # Clean build artifacts
make expunge             # Hard clean including downloaded tools
```

## Testing

Test framework: **Busted** (configured in `.busted`). Test config: `spec/kong_tests.conf`.

```bash
make test                                              # Unit tests (spec/01-unit/)
make test-integration                                  # Integration tests (spec/02-integration/) - needs Postgres
make test-plugins                                      # Plugin tests (spec/03-plugins/) - needs Postgres
make test-all                                          # All tests
make test-custom test_spec=spec/01-unit/path_spec.lua  # Run a specific test file
make lint                                              # Luacheck linting
make test-logs                                         # Tail test error logs
```

Test directories: `spec/01-unit/`, `spec/02-integration/`, `spec/03-plugins/`, `spec/04-perf/`, `spec/05-migration/`.

Environment variables: `KONG_TEST_xxx` overrides `KONG_xxx` for tests. `KONG_TEST_COVERAGE=1` enables luacov. `KONG_SPEC_TEST_REDIS_HOST` sets Redis host.

## Architecture

- `kong/init.lua` — Core initialization and request lifecycle
- `kong/cmd/` — CLI commands (start, stop, migrations, etc.)
- `kong/conf_loader/` — Configuration loading and parsing
- `kong/db/` — Database abstractions and schemas (Postgres, Cassandra)
- `kong/router/` — Request routing engine
- `kong/runloop/` — Main event loop and request processing
- `kong/pdk/` — Plugin Development Kit (the `kong.*` API available to plugins)
- `kong/api/` — Admin API implementation
- `kong/clustering/` — Hybrid mode (Control Plane / Data Plane) clustering
- `kong/plugins/` — 60+ built-in plugins
- `kong/llm/` — LLM/AI gateway features
- `kong/vaults/` — Secret vault integrations
- `kong/tools/` — Utility modules
- `bin/kong` — Main CLI entry point (shell wrapper)

## Plugin Structure

Each plugin in `kong/plugins/<name>/` follows this pattern:

- `handler.lua` — Plugin logic implementing lifecycle hooks (access, header_filter, body_filter, log, etc.)
- `schema.lua` — Configuration schema validation
- `daos.lua` — Database models (optional)
- `migrations/` — DB migration scripts (optional)

## Commit Message Format

Follows conventional-commits: `<type>(<scope>): <subject>`

Types: `feat`, `fix`, `hotfix`, `tests`, `docs`, `style`, `perf`, `refactor`, `chore`

Scopes: `proxy`, `router`, `admin`, `balancer`, `core`, `dns`, `dao`, `cli`, `cache`, `deps`, `conf`, or a plugin name.

Subject: present imperative tense, not capitalized, no trailing period.

## Code Style

- Lua: 2-space indentation (see `.editorconfig`)
- Linting: luacheck with `ngx_lua` standard (tests use `ngx_lua+busted`)
- No max line length enforced
- See `CONTRIBUTING.md` "Code style" section for detailed Lua conventions
