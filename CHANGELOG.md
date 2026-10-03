# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.2] - 2026-10-02

### Fixed

- The action was using the GitHub graphql API which could not update a pull
  request. This has been changed to an explicit rest API call to update the
  pull request body if the release pull request was updated.

## [0.2.0] - 2026-09-02

### Changed

- The `.changelog` is no longer nested based on semver versions, but instead a
  flat structure of changelog slugs.

## [0.1.0] - 2026-08-09

### Added

- Composite action with `release` and `validate` modes.
- `.changelog/{major,minor,patch}/<slug>.md` entry format, with an optional
  `type:` header to pick the Keep a Changelog category.
- Version resolution from `max(latest git tag, newest CHANGELOG.md heading)`.
- Automatic `chore(release): vX.Y.Z` pull request that rewrites the changelog,
  optionally updates a `VERSION` file, and deletes consumed entries.
- Compare-style reference links at the bottom of the changelog.
- Dependency-free bash test suite under `tests`.
