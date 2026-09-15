## Status

Implementation complete; full IDD ensemble pending Claude weekly quota recovery. No merge, deployment, closure or verified tag.

## Evidence

The pinned SDK's `Server.waitUntilCompleted` awaits only its receive-loop task. The loop is launched by `Server.start`; the stdio read loop finishes its stream on a zero-byte read. This is not a direct join of the application's unstructured startup sync.

A separate instrumented copy used the actual application and SDK with an absent fixture database and harmless startup work. Ordinary cooperative resources exited 0.001–0.068s after EOF. With strict cooperative execution, an eight-second sleeping startup delayed exit 8.062s; a pure AppleScript delay exceeded a 12s observation window, after which the owned lab process was killed. Trace markers showed transport startup delayed until the blocking work ended. The serial-executor candidate exited all five controlled cases in 0.053–0.066s. This establishes a reproducible starvation route, not proof that every historical latency sample had the same cause.

The committed probe links real app object files, excluding only the production entry point, and runs the real Server/SDK with a stdin pipe. It injects the existing fake script runner and an absent test database path. The successful path exits through normal async-main return. Its startup fake blocks six seconds; EOF and initialize have two-second fixture deadlines. Separate controls cover ordinary resources, idle startup and twelve concurrent Mail calls (maximum simultaneous scripts: one). Compiler, target and SDK are read from the actual SwiftPM build description; this avoided an installed-toolchain mismatch (6.2.4 modules versus xcrun's 6.3.3 compiler). The target was macOS 13; execution was on the current host, not a macOS 13 machine.

## Validation

- `swift test --filter StdioShutdownTests`: five tests passed.
- Final full `swift test`: 1,225 tests, 10 skipped, 0 failures.
- Mutation in a separate copy: removing only MailController's executor selection makes the strict-pool EOF test fail after its deadline; this was a behavioral assertion failure, not a build failure.
- Independent Codex static review: PASS, no blocking regression found. It did not execute tests or independently establish historical causality.
- After review, handshake assertions were hardened to wait for a complete LF frame and check JSON-RPC version/no error; the five focused tests passed again. Runtime code did not change after the full suite.
- `git diff --check` and Spectra validation passed.

## Limits

The new probe performs no real Mail operation. Existing broader tests retain their prior startup/permission behavior. Its stdout/stderr are capture files; broken-pipe behavior is covered by the existing SIGPIPE/write-failure tests, not this new handshake fixture. One initialize response does not prove every tool remains responsive during Mail work. The queue preserves serial actor execution but is not a fixed thread or MainActor. No new cancellation/rollback guarantee is made for accepted Apple Events, running scripts, filesystem stalls or arbitrary OS starvation. Test cleanup requests kill/reap on failure; it is not an absolute bound on kernel process reaping.

The executor design follows [Swift SE-0392](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md), using the compatible UnownedJob entry point and actor-owned executor lifetime.
