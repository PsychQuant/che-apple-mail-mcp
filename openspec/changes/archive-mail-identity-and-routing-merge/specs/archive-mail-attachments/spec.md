## ADDED Requirements

### Requirement: Attachment routing configuration override granularity

The archive-mail workflow SHALL merge a user-supplied `attachment_routing` block with the built-in default routing table at **sub-key granularity**. A sub-key the user does not mention SHALL retain its built-in default value. A sub-key the user does mention SHALL replace the corresponding default value entirely; list-valued sub-keys SHALL NOT be appended to their defaults.

This replaces the previous whole-object semantics, under which supplying any `attachment_routing` block discarded every built-in default, so a user who wanted to add one keyword had to restate all six sub-keys.

The recognised sub-keys SHALL be `data_extensions`, `document_extensions`, `data_keywords`, `document_keywords`, `data_dir`, and `documents_dir`. An unrecognised sub-key SHALL be reported and ignored rather than silently accepted.

A user who intends to disable a built-in default list SHALL express that as an explicit empty list. An absent sub-key SHALL NOT be interpreted as a request to disable the default.

The classification precedence itself is unchanged: keyword match is evaluated before extension match, data before document within each tier, and an unmatched attachment defaults to document.

#### Scenario: Unmentioned sub-keys retain their defaults

- **WHEN** a configuration file supplies `attachment_routing` containing only `document_keywords`
- **THEN** `data_extensions`, `document_extensions`, `data_keywords`, `data_dir`, and `documents_dir` SHALL each retain their built-in default value

##### Example: Adding one keyword no longer requires restating the table

- **GIVEN** the built-in defaults set `data_extensions` to the list containing `xlsx`, and set `document_keywords` to a list that does not contain the term `calendar`
- **AND** the configuration file supplies `attachment_routing` whose only sub-key is `document_keywords`, set to a list containing `calendar`
- **WHEN** an attachment named `NTUcalendar115.xlsx` is classified
- **THEN** the keyword tier SHALL match `calendar` before the extension tier is consulted, and the attachment SHALL be classified as a document
- **AND** an attachment named `raw_indicators.csv` SHALL still be classified as data, because `data_extensions` retained its default

#### Scenario: A mentioned list replaces rather than extends its default

- **WHEN** a configuration file supplies a list-valued sub-key that also exists in the built-in defaults
- **THEN** the resulting value SHALL be exactly the user-supplied list, and SHALL NOT contain entries that appear only in the default list

##### Example: Replacement is total, not additive

- **GIVEN** the built-in `data_keywords` default contains `raw` and `codebook`
- **AND** the configuration file sets `data_keywords` to a list containing only `indicators`
- **WHEN** an attachment named `raw_notes.txt` is classified
- **THEN** the `raw` keyword SHALL NOT match, because the default list was replaced

#### Scenario: Disabling a default requires an explicit empty list

- **WHEN** a configuration file sets a list-valued sub-key to an empty list
- **THEN** that list SHALL match nothing, and classification SHALL continue through the remaining lists and tiers

#### Scenario: Unrecognised sub-key is reported

- **WHEN** a configuration file supplies an `attachment_routing` sub-key that is not one of the six recognised names
- **THEN** the workflow SHALL report that sub-key as unrecognised and SHALL continue using the built-in default for every recognised sub-key the user did not supply
