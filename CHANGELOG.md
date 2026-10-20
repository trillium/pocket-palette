# Changelog

All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning: docs/versioning.md.

## [0.2.0] - 2026-10-20

### Added
- Initial public release of PocketPalette: voice command palette that runs commands on a Mac engine.
- Reference Mac demo engine, dependency-free (`make demo-engine`).
- Semantic versioning from git tags: `scripts/version.sh`, `scripts/release.sh`, `docs/versioning.md`; version shown in Settings > About.

### Changed
- Version and build number are stamped automatically from git; `make bump` is removed.
