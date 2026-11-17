# hex-escape-decoding Specification

## Purpose

Defines when `=XX` (quoted-printable) and `%XX` (percent encoding) count as an escape, so a signed or non-ASCII digit pair is never decoded to a byte.

## Requirements

### Requirement: A hex escape is two ASCII hex digits

The quoted-printable decoders (`RFC822Parser.decodeQuotedPrintable`, used for bodies and RFC 2047 `Q` words, and `MailController.decodeQuotedPrintable`, used by the AppleScript fallback) and the percent decoder (`MIMEParser.decodePercentEncoded`) SHALL treat `=` or `%` followed by two characters as an escape only when both characters are ASCII hex digits (`0-9`, `A-F`, `a-f`), and SHALL read them through one shared `public` helper, `HexEscape.byte(_:_:)` in `MailSQLite`; no other character (a sign, a space, a fullwidth digit) SHALL be accepted, and no `radix: 16` parse SHALL remain in `Sources`. A `=` that does not start an escape SHALL stay in the output as `=` and the characters after it SHALL be kept, in the AppleScript decoder as well; a `%` that does not start an escape SHALL make `decodePercentEncoded` return nil, as any other malformed percent escape does. Valid escapes in either case SHALL decode as before.

#### Scenario: A signed pair is not an escape

- **WHEN** a quoted-printable part contains `=+5`
- **THEN** every decoder keeps the three characters as text and none produces the byte 0x05

##### Example: hex escape decoding

| Input | Quoted-printable (both decoders) | Percent decoder |
| --- | --- | --- |
| `=C3=A9` / `%C3%A9` | the bytes C3 A9 (`é`) | `é` |
| `=c3=a9` / `%c3%a9` | the bytes C3 A9 (`é`) | `é` |
| `=+5` / `%+5` | the text `=+5` | nil |
| `=-0` / `%-0` | the text `=-0` | nil |
| `=+a` / `%+a` | the text `=+a` | nil |
| `=ZZ` / `%ZZ` | the text `=ZZ` | nil |
| `=０５` / `%０５` (fullwidth digits) | the text `=０５` | nil |
| `abc=4` (escape cut off at the end) | the text `abc=4` | not applicable |
