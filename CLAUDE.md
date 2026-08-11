# Bluebird — contributor guide for Claude

## Before committing

Always run `dart analyze` **and** `dart format` on every changed Dart file
before committing — CI enforces both (`ci.yml` runs `dart analyze` plus a
`dart format` check and fails on any finding or reformat).

- Use `fvm dart` / `fvm flutter`, not the bare binaries.
- Format at 120 columns: `fvm dart format <changed files>` (each package's
  `analysis_options.yaml` sets `page_width: 120`, which `dart format` reads
  automatically when run inside the package).
- Analyze: `fvm dart analyze <changed files>` (or `fvm flutter analyze` for a
  whole package).

Do this before staging so a follow-up "fix formatting" commit is never needed.
