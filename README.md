<p align="center">
  <img src="assets/nshkr.svg" width="200" height="200" alt="NSHKR logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/nshkr">
    <img alt="GitHub: nshkr" src="https://img.shields.io/badge/GitHub-nshkr-0b0f14?logo=github" />
  </a>
  <a href="https://github.com/nshkrdotcom/nshkr/blob/main/LICENSE">
    <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-0b0f14.svg" />
  </a>
</p>

# NSHKR

NSHKR is the production Elixir/OTP composition and release workspace for a governed AI operations platform, wiring durable workflows, cognitive context, provider accounts, policy decisions, execution runtimes, cluster reconciliation, Synapse, and Extravaganza into reproducible monolith and distributed deployments.

## Runtime composition

`Nshkr.Runtime` is the single production composition root for owner-ordered
Postgres persistence and migrations, secret and object stores, durable
Mezzanine workflows, Citadel authority, Jido provider accounts, OuterBrain
context, Execution Plane effects, Chassis reconciliation, AppKit, Synapse, and
Extravaganza. Production profiles are fail-closed: memory, fixture, no-op, and
static-success backends are not valid release selections.

## Poncho layout

This repository is a poncho-style, non-umbrella workspace:

- the root Mix project owns workspace tooling, metadata, and cross-project commands;
- `apps/nshkr_runtime` is the independently buildable production OTP application.

Each project owns its own build, dependency, and lock state. The root never
becomes the release application.

## Development

Install and compile the tooling root:

```bash
mix deps.get
mix compile
```

Compile the runtime application independently:

```bash
cd apps/nshkr_runtime
mix deps.get
mix compile
```

The runtime supervision tree is the integration point for the owner services
frozen by the NSHKR implementation program. Product code receives the
host-built AppKit backend stack and does not start lower owner services.

For the real single-host developer profile, start Vault and MinIO with
`apps/nshkr_runtime/priv/dev/services.sh up`, provide the four owner database
URLs plus the canonical `NSHKR_SYNAPSE_PROGRAM_ID` and
`NSHKR_SYNAPSE_WORK_CLASS_ID` routing identifiers named by
`Nshkr.Runtime.DeveloperLocalProfile`, and set
`NSHKR_PROFILE_FILE` to `apps/nshkr_runtime/priv/dev/profile.exs`. Boot performs
migration-head, Postgres, Vault, MinIO, Temporal, owner-store, outbox, and
capability-truth preflight before any configured product endpoint can start.
