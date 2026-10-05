# Combined feature checks

`CombinedDiscoveryUITests.swift` contains saved-capture citation checks and a
cold-search-route flow that uses system search, local answers and
`CapdPhoneFixtureHost`.

The `CapdPhoneUITests` target in `../project.yml` includes `../UITests`, not this
directory. `../UITests/AnswersUITests.swift` is part of that configured target;
these combined checks are not.

These fixtures create captures and change system-search settings. Use an
isolated synthetic simulator library, not a personal phone or library.
