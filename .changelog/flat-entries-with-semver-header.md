semver: major
type: Changed
Changelog entries are now a single flat file per change, `.changelog/<slug>.md`,
with a required `semver: major|minor|patch` header instead of a bump-level
directory.

`type:` is still optional and may sit either side of `semver:`. A missing or
unrecognised `semver:` fails the run rather than defaulting, and a file left in
`.changelog/{major,minor,patch}/` is reported as an error instead of being
silently skipped. See "Upgrading from v1" in the README for the migration.
