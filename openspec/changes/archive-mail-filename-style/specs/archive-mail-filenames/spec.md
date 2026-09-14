## ADDED Requirements

### Requirement: Explicit style and compatibility
Both export tool aliases SHALL accept optional `opts.filename_style` with values `default` and `archive-mail`; omitted SHALL mean default. Unknown values and non-string values SHALL produce an invalid-parameter error. Per-id filenames SHALL take priority over filename_template, which SHALL take priority over style. Existing default and template outputs SHALL remain unchanged.

#### Scenario: Style with explicit overrides
- **WHEN** archive-mail style, a template, and a per-id filename are supplied
- **THEN** the per-id filename SHALL win for that id and the template SHALL win for other ids

#### Scenario: Invalid style
- **WHEN** filename_style is null, true, or `archive`
- **THEN** the request SHALL fail with invalid parameter before export writes

### Requirement: Archive subject transformation
Archive-mail style SHALL use raw subject including reply prefixes. Each Swift Character classified as whitespace or punctuation, containing a slash, backslash, or C0/C1 control scalar SHALL map to one dash. Other Unicode including emoji SHALL be retained. Consecutive dashes SHALL remain separate. The mapped string SHALL be truncated to 50 extended grapheme clusters, then trimmed of leading and trailing dashes; an empty result SHALL become `no-subject`.

#### Scenario: Reply and Unicode preserved
- **WHEN** subject is `Re: 中文 🇹🇼 👩‍👩‍👧‍👦`
- **THEN** its slug SHALL be `Re--中文-🇹🇼-👩‍👩‍👧‍👦`

#### Scenario: Truncation precedes trim
- **WHEN** subject is a space followed by 50 letters `a`
- **THEN** its slug SHALL contain 49 letters `a`

### Requirement: Shared Date-header value
The exporter SHALL pass its single offset-preserving Date-header conversion result to the renderer and derive the filename calendar prefix from that value. It SHALL NOT derive the prefix from search timestamps or the host timezone. Values without a leading YYYY-MM-DD shape SHALL use `unknown-date` and retain existing frontmatter rendering. Existing parser acceptance and calendar validation behavior SHALL remain unchanged.

#### Scenario: Negative offset crosses UTC midnight
- **WHEN** the Date header is `Fri, 06 Mar 2026 23:49:56 -0500`
- **THEN** the filename SHALL start `2026-03-06_` and frontmatter date SHALL be `2026-03-06T23:49:56-05:00`

### Requirement: One collision authority
Archive style SHALL seed the existing case-folded collision guard from on-disk markdown files and apply it across the batch. The first available name SHALL be unsuffixed or the smallest available positive -N suffix. The manifest written_path SHALL identify the actual file.

#### Scenario: Existing name and two same-subject messages
- **WHEN** `2026-03-06_RE--X.md` exists and two `Re: x` messages are exported
- **THEN** their filenames SHALL be `2026-03-06_Re--x-1.md` and `2026-03-06_Re--x-2.md` without changing the existing file

### Requirement: SOP uses server naming capability
The archive-mail batch workflow SHALL check tool schema support and use `filename_style: archive-mail` without generating routine filenames overrides. Unsupported tools SHALL use per-email fallback with the fetched Date-header source. Downstream attachment and index filenames SHALL come from manifest written_path for batch output.

#### Scenario: Old tool schema
- **WHEN** the tool schema lacks archive-mail filename_style support
- **THEN** the workflow SHALL use per-email fallback and SHALL NOT pass a silently ignored style to batch export
