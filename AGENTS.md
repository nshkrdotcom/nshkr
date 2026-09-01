# NSHKR workspace instructions

## Ownership

- The repository root is tooling-only and must remain a non-umbrella Mix project.
- `apps/nshkr_runtime` owns the production OTP composition and release application.
- Product code consumes lower owners through AppKit; composition code must not create a product bypass.

## Dependency sources

- Cross-repository source substitution uses MWO's documented tuple-first
  `workspace_dep(committed_tuple)` seam in `apps/nshkr_runtime/mix.exs`. Committed tuples
  are standalone Hex defaults; MWO activation substitutes only source coordinates.
- Machine-local source preferences belong in MWO's XDG operator state. Do not install a
  repository-local dependency-source helper or override file.
- Do not select dependency sources through environment variables.
- Keep the committed Blitz and Weld dependencies on current released Hex versions.

## Verification

- Compile the root tooling project with `mix compile`.
- Compile the production application from `apps/nshkr_runtime` with `mix compile`.
- Use the P01 technical document for production composition and security gates.
