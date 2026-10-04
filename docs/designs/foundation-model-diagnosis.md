# Synthetic Foundation Models diagnostics

The sources under `Scripts/Diagnostics` probe token counting, plain generation,
a small structured response, and the unchanged local answer adapter. All prompts
and evidence are fixed synthetic orchid text. They accept no library, capture,
credential or remote-model input and use a 45-second process limit.

These programs are explicit diagnostics, separate from the app and default tests.
Their raw framework errors are useful only for synthetic troubleshooting and are
not copied into production question/evidence logging. Availability alone does not
establish successful generation. A simulator's model-service failure does not
prove a specific download, entitlement, prompt or schema issue.

Compile the host probe from the repository root:

```sh
xcrun swiftc -parse-as-library -swift-version 6 -D FULL_CAPD_PROBE \
  Scripts/Diagnostics/FoundationModelProbe.swift \
  Packages/CapdAnswers/Sources/CapdAnswers/GroundedAnswers.swift \
  Packages/CapdAnswers/Sources/CapdAnswers/OnDeviceAnswerModel.swift \
  -o /tmp/capd-synthetic-model-probe
```

Running that executable invokes the local framework with synthetic text. The
separate `FoundationModelProbeApp.swift` and its generic plist support an isolated
simulator diagnostic bundle; compiling the main phone project does not run it.
`SIMPLE_PROBE` omits structured and adapter requests. `FULL_CAPD_PROBE` includes
the unchanged adapter and grounded service. `PROBE_APP` selects the dedicated app
entrypoint. Successful native generation still requires an explicit runtime check
on the intended host or an authorized disposable simulator/device.

No token, schema or validation bounds are relaxed to bypass a framework failure,
and no remote fallback is supplied.
