## ADDED Requirements

### Requirement: Isolate blocking Mail work from stdio progress
MailController SHALL execute actor jobs on a stable serial executor separate from Swift's cooperative executor pool. Blocking startup sync SHALL NOT occupy the cooperative worker needed by the SDK receive loop.

#### Scenario: Handshake during blocked startup
- **WHEN** the controlled probe constrains the cooperative pool and blocks the fake startup script for six seconds
- **THEN** the real SDK SHALL answer initialize within the two-second fixture deadline without waiting for that script to complete

#### Scenario: EOF during blocked startup
- **WHEN** stdin closes after the fake startup script has started under either constrained or ordinary cooperative resources
- **THEN** the probe SHALL return normally with exit code zero within the two-second fixture deadline

### Requirement: Preserve Mail actor behavior
The executor SHALL retain actor mutual exclusion and execute each enqueued job exactly once. Existing script timeout, preflight, startup-sync, GUI/subprocess and error semantics SHALL remain in effect.

#### Scenario: Concurrent Mail calls
- **WHEN** multiple tasks invoke synchronous Mail methods through the injected script runner
- **THEN** script calls SHALL execute without overlap and each caller SHALL receive its result or existing typed error

### Requirement: Verify the production lifecycle without real Mail operations
The shutdown probe SHALL link the actual application objects and use the real SDK transport with stdin pipes. Its fake script and database path SHALL be test-owned; production defaults SHALL remain unchanged.

#### Scenario: Normal startup control
- **WHEN** fake startup work completes immediately
- **THEN** EOF SHALL still produce a clean exit and no real Mail or user database operation SHALL be required
