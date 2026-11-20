## ADDED Requirements

### Requirement: forward_email refuses a body that is not a string

`forward_email` SHALL treat its optional `body` as absent only when the key is missing or its value is `null`. When `body` is present with any other value that is not a string, the system SHALL refuse the call with an invalid-parameter error that names `body` and the type it received, before any Mail operation, whether or not `save_as_draft` is set; it SHALL NOT read such a value as a missing body. A string, including the empty string, SHALL be handled as before.

#### Scenario: A number as the body does not become a bare forward

- **WHEN** `forward_email` is called with `body: 5` and no `save_as_draft`
- **THEN** the call fails with an invalid-parameter error naming `body` and `integer`, and no Mail script runs

#### Scenario: A missing or null body is still a bare forward

- **WHEN** `forward_email` is called without `body`, or with `body: null`
- **THEN** the native forward script runs, as before

##### Example: forward_email body types

| body | save_as_draft | Result |
| --- | --- | --- |
| `5` | omitted | refused: `'body' must be a string, got: integer`; no Mail script |
| `1.5` | omitted | refused: `got: number`; no Mail script |
| `true` | omitted | refused: `got: boolean`; no Mail script |
| `["note"]` | omitted | refused: `got: array`; no Mail script |
| `{"text": "note"}` | omitted | refused: `got: object`; no Mail script |
| `5` | `true` | refused: `'body' must be a string, got: integer` (not the bare-forward draft refusal); no Mail script |
| missing | omitted | native forward script ending in `send` (unchanged) |
| `null` | omitted | native forward script ending in `send` (unchanged) |
| `"FYI"` | omitted | paste path with the send keystroke (unchanged) |
