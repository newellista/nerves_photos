# Local CI & Pipeline Hardening Design

**Date:** 2026-05-04
**Branch:** feature/housekeeping

## Problem

- No way to run CI checks locally before pushing — catching failures requires a round-trip to GitHub Actions.
- The pipeline only runs compile, format, and test. No linting or dependency vulnerability scanning.

## Goal

1. A `mix ci` alias that runs all quality checks locally with zero extra tooling.
2. An enhanced CI `test` job that uses the same alias, so local and CI are always in sync.

## New Dependencies

Add to `deps/0` in `mix.exs`, scoped to `:dev` only:

```elixir
{:credo, "~> 1.7", only: :dev, runtime: false},
{:mix_audit, "~> 2.1", only: :dev, runtime: false},
```

## The `mix ci` Alias

Add to `aliases/0` in `mix.exs`:

```elixir
ci: [
  "compile --warnings-as-errors",
  "format --check-formatted",
  "credo --strict",
  "deps.audit",
  "hex.audit",
  "test"
]
```

Running `mix ci` locally is the canonical pre-push check. It covers:

| Step | Tool | Catches |
|---|---|---|
| `compile --warnings-as-errors` | built-in | Code issues, unused vars |
| `format --check-formatted` | built-in | Formatting drift |
| `credo --strict` | credo | Style, complexity, consistency |
| `deps.audit` | mix_audit | Known CVEs in deps |
| `hex.audit` | built-in | Retired/deprecated packages |
| `test` | built-in | Regressions |

## Updated CI Workflow — `test` Job

Replace the individual compile/format/test `run:` steps with a single `mix ci` call. System packages and `mix deps.get` stay as-is.

```yaml
- run: mix deps.get
- run: mix ci
```

The `firmware` job is unchanged.

## Out of Scope

- Dialyzer: too slow and noisy with Nerves deps at this project stage.
- Docker/`act`-based local CI: deferred in favour of native speed.
- `sobelow`: Phoenix-specific scanner, not applicable (project uses Plug/Cowboy directly).
