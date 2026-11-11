## ADDED Requirements

### Requirement: forward_email can save the forward as a draft

`forward_email` SHALL accept an optional boolean `save_as_draft`, default `false`; a value that is not a boolean SHALL be rejected as an invalid parameter rather than read as `false`. When `save_as_draft` is `true` and a body is given, the system SHALL open the forward with Mail's native forward verb, paste the body at the cursor, set the recipients, and save the forward as a draft with the save keystroke instead of the send keystroke, so that nothing is sent; it SHALL report `Forward saved as draft (paste path)`. When `save_as_draft` is `true` and no body is given, the system SHALL refuse the call with an invalid-parameter error that names the reason and the alternatives (pass a body, or forward in Mail by hand) before any Mail operation, because the bodyless forward is Mail's native forward verb followed by a send, with no keystroke step that could save it; this refusal is temporary and SHALL be removed when a bodyless draft mode exists (#673). When `save_as_draft` is `false` or omitted, the behaviour SHALL be unchanged: the forward is sent. A timeout or a post-dispatch failure on the send path SHALL keep the existing unknown-send-state handling exactly; on the draft path a timeout SHALL NOT be reported as an unknown send state. The tool description SHALL state that the call sends the forward unless `save_as_draft` is `true`, and SHALL advise reading a saved draft back before sending it. This refusal is a parameter refusal, not an ineligibility reason of Requirement: Ineligible composing calls fail without side effects.

#### Scenario: A forward with a note is saved as a draft

- **WHEN** `forward_email` is called with a body and `save_as_draft: true`
- **THEN** the GUI script it runs ends with the save keystroke, contains no send keystroke, and reports `Forward saved as draft (paste path)`

#### Scenario: A bare forward cannot be saved as a draft yet

- **WHEN** `forward_email` is called without a body and with `save_as_draft: true`
- **THEN** it fails with an invalid-parameter error naming the reason and #673, and no Mail script runs

#### Scenario: A draft-flow timeout is not an unknown send state

- **WHEN** the GUI script of a `save_as_draft: true` forward times out
- **THEN** the error is not the unknown-send-state error, while a timeout of a sending forward still is

##### Example: forward_email save_as_draft

| body | save_as_draft | Result |
| --- | --- | --- |
| `"FYI"` | `true` | paste path, save keystroke, no send keystroke, `Forward saved as draft (paste path)` |
| `"FYI"` | omitted | paste path, send keystroke (unchanged) |
| `"FYI"` | `false` | paste path, send keystroke (unchanged) |
| none | `true` | refused before any Mail operation, naming #673 |
| none | omitted | native forward script ending in `send` (unchanged) |
| `"FYI"` | `"yes"` (a string) | refused: save_as_draft must be a boolean |
