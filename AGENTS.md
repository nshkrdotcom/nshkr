# NSHKR workspace instructions

## Ownership

- The repository root is tooling-only and must remain a non-umbrella Mix project.
- `apps/nshkr_runtime` owns the production OTP composition and release application.
- Product code consumes lower owners through AppKit; composition code must not create a product bypass.

## Dependency sources

- Cross-repository source selection belongs in `build_support/dependency_sources.config.exs`.
- Local dependency overrides use `.dependency_sources.local.exs`, which must remain untracked.
- Do not select dependency sources through environment variables.
- Keep the committed Blitz and Weld dependencies on current released Hex versions.

## Verification

- Compile the root tooling project with `mix compile`.
- Compile the production application from `apps/nshkr_runtime` with `mix compile`.
- Use the P01 technical document for production composition and security gates.
