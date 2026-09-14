## ADDED Requirements

### Requirement: Explicit signature policy
compose_email, create_draft and update_draft SHALL accept signature.mode mail_default, none or named. Omission SHALL mean mail_default. Only named SHALL accept and require a nonempty name. Unknown fields and malformed values SHALL be rejected before GUI work.

#### Scenario: Named signature
- **WHEN** signature is {mode: named, name: Professional}
- **THEN** the new message SHALL request that exact Mail signature without appending signature text to the supplied body

### Requirement: Guarded native selection
The workflow SHALL select the signature after From selection and before attachments and dispatch, using the identified compose window and popup_signature AXIdentifier. Explicit modes SHALL refuse missing or ambiguous controls. Before AX title lookup, the original native window id and title SHALL still match; after AXRaise and before signature changes or dispatch, the native front id SHALL equal that original id. Identity failure SHALL NOT discard a replacement or user-edited window. Both None and named selections SHALL verify the unique checked menu item and recheck before dispatch. Named mode SHALL require one global definition and one eligible exact menu item within the bounded signature section, excluding management footer commands; it SHALL select native None first, then the requested name. The None item SHALL be validated by role, enabled state, position and a supported label rather than position alone.

#### Scenario: Unknown menu shape
- **WHEN** explicit signature selection cannot identify the native None item
- **THEN** the workflow SHALL refuse before sending or saving rather than click a guessed item

### Requirement: Honest signature receipt
The workflow SHALL return a structured selection receipt encoded in a fixed suffix before the Bcc suffix. It SHALL distinguish selection verification from body insertion verification and SHALL NOT claim body insertion from popup state alone. mail_default SHALL preserve Mail selection and disclose unavailable readback without blocking legacy behavior. Explicit receipt mismatch after dispatch SHALL preserve post-dispatch uncertainty and SHALL NOT trigger a retry.

#### Scenario: Bcc and signature coexist
- **WHEN** a draft reveals Bcc and selects a named signature
- **THEN** both disclosures SHALL survive suffix parsing without raw encoded tokens leaking into the human result

### Requirement: Preserve body and replacement semantics
The implementation SHALL NOT heuristically remove or append caller body text. update_draft SHALL forward the signature policy to the replacement draft while preserving its existing create-before-delete checks. reply/forward behavior SHALL remain unchanged.

#### Scenario: Caller supplies a manual signature
- **WHEN** body contains user-authored closing text and mode none is selected
- **THEN** only Mail's native signature selection SHALL be disabled and the caller text SHALL remain unchanged
