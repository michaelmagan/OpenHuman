# AGENTS.md

Guidance for coding agents working on this repository's source. For agents that
drive the `openhuman` CLI or MCP server as users, see
[docs/cli/AGENTS.md](docs/cli/AGENTS.md) and
[skills/openhuman-mail](skills/openhuman-mail/SKILL.md) instead.

## Start here

- Overview: [README.md](README.md)
- Build and test: [docs/BUILD.md](docs/BUILD.md) (iOS: [docs/IOS-BUILD.md](docs/IOS-BUILD.md))
- Contribution rules: [CONTRIBUTING.md](CONTRIBUTING.md)
- CI scripts: [Tools/ci/](Tools/ci/) (`build-*.sh`, `test-all.sh`, `check-imports.sh`)
- Building and testing need macOS with Xcode. A Linux container cannot build the
  app or run its tests; say so rather than claiming a change was verified.

## Keeping AGENTS.md current

- When code review or human feedback shows an agent worked from an incorrect
  assumption, record the correction in the relevant AGENTS.md in that same PR.
  Keep entries short and factual, and delete stale ones.
- A subdirectory (for example a package under `Packages/` or a tool under
  `Tools/`) gets its own AGENTS.md when it has non-obvious conventions. The
  nearest AGENTS.md applies.

## Pull requests

Before opening a PR, run `/code-review` on the diff. Fix the obvious issues and
confirm anything ambiguous with the user before pushing.
