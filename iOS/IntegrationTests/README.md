# Combined feature checks

`CombinedDiscoveryUITests.swift` is preserved outside the standalone iPhone test
target because its cold-search-route flow requires both system search and local
answers. It is not part of the Q&A branch's independent acceptance checks.

After both feature branches are integrated, include this directory in the owned
synthetic simulator test target to exercise the combined flow. Do not run these
capture-creating fixtures against a personal phone or library. The ordinary
`UITests/AnswersUITests.swift` remains in the Q&A target.
