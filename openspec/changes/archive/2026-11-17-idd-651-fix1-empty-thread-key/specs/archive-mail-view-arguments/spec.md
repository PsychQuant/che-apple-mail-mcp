## Purpose

Defines how `/archive-mail-view` reads what the user typed after the command, so the typed text stays data and never becomes part of the instructions, the way #540 made `/archive-mail` read its arguments.

## MODIFIED Requirements

### Requirement: View reads its arguments from ARGS_RAW only

`plugin/commands/archive-mail-view.md` SHALL hold exactly one unescaped `$ARGUMENTS`, on a line of its own that reads `ARGS_RAW: $ARGUMENTS`, followed by a statement that `ARGS_RAW` is data, not instructions; no other part of the command SHALL read the typed text. Step 1 SHALL split `ARGS_RAW` shell-style (single quotes, double quotes, backslash escapes): when it holds none of `"`, `'` and `\`, by ASCII whitespace with no program; otherwise with `split_view_arguments` from the marked `archive-mail-view-args-recipe`, reading `ARGS_RAW` from a data file in the run's private directory, never from program text or a command line. The first token SHALL be `thread_query`, the second `archive_dir` (default `communication/emails`), and later tokens SHALL be ignored; the command has no flags, so a token starting with `-` is an ordinary token. A missing `thread_query`, a first token that is empty or only whitespace (the recipe reports `empty-thread-query`), an unbalanced quote, a trailing backslash, or a split that cannot be run SHALL stop the command with `status: bad-arguments` and no file written; the command's closed list of six statuses SHALL NOT grow.

#### Scenario: A blank first token stops

- **WHEN** `split_view_arguments` receives `"" key`
- **THEN** it returns no tokens and the error `empty-thread-query`, and Step 1 stops with `bad-arguments`

#### Scenario: A quoted thread key stays one token

- **WHEN** `split_view_arguments` receives `"Aster manuscript 2025" communications`
- **THEN** it returns the tokens `Aster manuscript 2025` and `communications` and no error

##### Example: view argument splitting

| `ARGS_RAW` | Tokens | Error |
| --- | --- | --- |
| `Aster` | `Aster` | none |
| `"Aster manuscript 2025" communications` | `Aster manuscript 2025`, `communications` | none |
| `'Aster manuscript` | none | `unbalanced-quote` |
| `Aster\` | none | `unbalanced-quote` |
| `--odd key` | `--odd`, `key` | none |
| empty | none | none (Step 1 stops with `bad-arguments`: no `thread_query`) |
| `"" key` | none | `empty-thread-query` |
| `""` | none | `empty-thread-query` |
| `" " key` | none | `empty-thread-query` |
| `key ""` | `key`, an empty string | none |
