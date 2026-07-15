## ADDED Requirements

### Requirement: Wrapper-free strictness parameter

`compose_email` and `create_draft` SHALL accept an optional boolean `require_wrapper_free` (default false). When true and the wrapper-free mailto path is ineligible (custom sender, non-plain format, empty subject, Accessibility not granted, or the env hatch set), the tool SHALL fail with an error naming the ineligibility reason and actionable alternatives, and SHALL NOT create any draft or send any mail via the legacy injection path. When true and the wrapper-free path is attempted but fails, the error SHALL propagate without a legacy fallback (the #242 post-dispatch semantics are unchanged). When false or omitted, behavior SHALL be identical to the pre-existing graceful-fallback contract, including its disclosure suffix.

#### Scenario: Strict compose refuses an ineligible call without side effects

- **WHEN** `compose_email` is called with `require_wrapper_free: true` and a custom `from_address`
- **THEN** the tool SHALL return an error naming the custom-sender reason and the alternatives (omit `from_address` and switch sender manually; see #219)
- **AND** no draft SHALL be created and no mail SHALL be sent

#### Scenario: Strict compose propagates a clean-path failure without fallback

- **WHEN** `compose_email` is called with `require_wrapper_free: true`, the call is eligible, and the mailto GUI path throws
- **THEN** the error SHALL propagate to the caller
- **AND** the legacy injection path SHALL NOT run

#### Scenario: Default remains graceful fallback

- **WHEN** `compose_email` is called without `require_wrapper_free` (or with false) and the call is ineligible
- **THEN** the legacy path SHALL run and the result SHALL carry the `[legacy path — …]` disclosure suffix, exactly as before
