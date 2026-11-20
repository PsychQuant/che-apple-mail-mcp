## MODIFIED Requirements

### Requirement: forward_email refuses a body that is not a string

`forward_email` SHALL treat its optional `body` as absent only when the key is missing or its value is `null`. An explicit `null` is read as a missing key, as the server reads `null` for its other optional parameters; so a call with `body: null` and without `save_as_draft` is a forward without a body and is sent, and the parameter description SHALL say so. When `body` is present with any other value that is not a string, the system SHALL refuse the call with an invalid-parameter error that names `body` and the type it received, after the message id and the required arguments (`mailbox`, `account_name`, `to`) have been validated, before the account is resolved and before any Mail operation, whether or not `save_as_draft` is set; it SHALL NOT read such a value as a missing body. A JSON string that parses as a `data:` URL reaches the tool as binary data (the MCP SDK decodes it so), and SHALL be refused the same way, with a message that says why it reads as data. A string, including the empty string, SHALL be handled as before.

#### Scenario: A number as the body does not become a bare forward

- **WHEN** `forward_email` is called with `body: 5` and no `save_as_draft`
- **THEN** the call fails with an invalid-parameter error naming `body` and `integer`, and no Mail script runs

#### Scenario: A missing or null body is still a bare forward

- **WHEN** `forward_email` is called without `body`, or with `body: null`, and `save_as_draft` is omitted or `false`
- **THEN** the native forward script runs, as before; with `save_as_draft: true` the same call is refused by Requirement: forward_email can save the forward as a draft

##### Example: forward_email body types

| body | save_as_draft | Result |
| --- | --- | --- |
| `5` | omitted | refused: `'body' must be a string, got: integer`; no Mail script |
| `1.5` | omitted | refused: `got: number`; no Mail script |
| `true` | omitted | refused: `got: boolean`; no Mail script |
| `["note"]` | omitted | refused: `got: array`; no Mail script |
| `{"text": "note"}` | omitted | refused: `got: object`; no Mail script |
| `5` | `true` | refused: `'body' must be a string, got: integer` (not the bare-forward draft refusal); no Mail script |
| `5`, with an `account_name` that matches two accounts | omitted | refused for the body (`got: integer`), not for the account; no Mail script |
| `"data:text/plain;base64,SGVsbG8="` | omitted | refused: `got: data`, with the reason (decoded as binary data); no Mail script |
| missing | omitted | native forward script: `send fwdMsg`, no keystroke (unchanged) |
| `null` | omitted | native forward script: `send fwdMsg`, no keystroke (unchanged) |
| missing | `true` | refused as a bare forward that cannot be saved as a draft (#673); no Mail script |
| `null` | `true` | refused as a bare forward that cannot be saved as a draft (#673); no Mail script |
| `"FYI"` | omitted | paste path: clipboard set to the body, then the paste keystroke, then the send keystroke (unchanged) |
| `""` | omitted | paste path: clipboard set to the body, then the paste keystroke, then the send keystroke (unchanged) |
