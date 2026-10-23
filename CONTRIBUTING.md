# Contributing

Issues and pull requests are welcome. For a substantial feature or architecture
change, open an issue to discuss the behavior before implementation. Include
reproduction steps and expected behavior when reporting a bug; use synthetic
mail and remove account identifiers from diagnostics.

Build requirements and commands are in [docs/BUILD.md](docs/BUILD.md).
Create a feature branch, make a focused change, and run checks relevant to the
packages or app surfaces you changed. Include the results in your PR.

```sh
Tools/ci/check-imports.sh
(cd Packages/OpenHumanMailCore && swift test)
```

Changes spanning packages should also pass `Tools/ci/test-all.sh` and the app
tests. Keep meaningful regression coverage for changed behavior. Public API
changes should update the relevant CLI schema or user documentation.

Coding agents should follow [AGENTS.md](AGENTS.md).

Keep generated projects, build output, machine-specific settings, OAuth
credentials, signing keys, and real mail data out of commits. Preserve existing
copyright and license notices. Contributions are provided under the project's
Apache 2.0 license.
