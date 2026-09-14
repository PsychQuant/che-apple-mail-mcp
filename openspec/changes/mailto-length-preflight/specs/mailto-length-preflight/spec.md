## ADDED Requirements

### Requirement: Exact encoded length
The preflight SHALL calculate the actual ASCII mailto URL length using UTF-8 percent-encoding and the same recipient partition as compose. It SHALL include subject, recipient delimiters and optional cc/bcc fields, and SHALL report total, body, other, limit, remaining and fits.

#### Scenario: CJK and Unicode body
- **WHEN** the body contains CJK, emoji, combining characters or CRLF
- **THEN** the reported total SHALL equal the actual builder output length

### Requirement: Named no-side-effect refusal
compose_email, create_draft and update_draft SHALL reject encoded totals above 8000 with MAILTO_URL_TOO_LONG before any Mail query or GUI operation. Exactly 8000 SHALL remain permitted by this check. The error SHALL include measured total/body/limit and actionable manual-paste or explicitly approved splitting guidance.

#### Scenario: Oversized replacement draft
- **WHEN** update_draft receives an over-limit body
- **THEN** it SHALL refuse before locating, creating or deleting drafts

### Requirement: Read-only preflight and consistent guidance
check_compose_length SHALL expose the exact calculation without Mail access and SHALL disclose that other eligibility conditions remain unchecked. Repo, plugin and global compose rules SHALL document the same named length failure and SHALL NOT claim a legacy fallback exists.

#### Scenario: Fits is not full eligibility
- **WHEN** check_compose_length returns fits=true
- **THEN** it SHALL also report other_requirements_checked=false
