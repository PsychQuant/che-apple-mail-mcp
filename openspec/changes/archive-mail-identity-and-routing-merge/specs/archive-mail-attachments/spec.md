## Purpose

Defines how `/archive-mail` merges a user `attachment_routing` block with the built-in routing defaults and in which order attachments are classified as data or document.

## ADDED Requirements

### Requirement: Attachment routing configuration override granularity

The archive-mail workflow SHALL merge a user-supplied `attachment_routing` block with the built-in default routing table at **sub-key granularity**. A sub-key the user does not mention SHALL retain its built-in default value. A sub-key the user does mention SHALL replace the corresponding default value entirely; list-valued sub-keys SHALL NOT be appended to their defaults.

This replaces the previous semantics, under which supplying any `attachment_routing` block emptied every one of the four default lists the user did not restate (`data_dir` and `documents_dir` already kept their defaults), so a user who wanted to add one keyword had to restate all four lists.

The recognised sub-keys SHALL be `data_extensions`, `document_extensions`, `data_keywords`, `document_keywords`, `data_dir`, and `documents_dir`. An unrecognised sub-key SHALL be reported and ignored rather than silently accepted.

A user who intends to disable a built-in default list SHALL express that as an explicit empty list; a list sub-key that is present with no value (YAML null) SHALL be treated the same as an explicit empty list and SHALL be disclosed in the run report. An absent sub-key SHALL NOT be interpreted as a request to disable the default. List items SHALL be compared case-insensitively, and empty or whitespace-only items SHALL be discarded with a warning.

Classification order is defined by the requirement "Attachment routing classifies user-written lists before retained defaults" below.

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

#### Scenario: A list key with no value disables that list

- **WHEN** a configuration file writes `document_keywords:` with no value
- **THEN** `document_keywords` SHALL match nothing, and the run report SHALL state that the list is empty and disabled

#### Scenario: Unrecognised sub-key is reported

- **WHEN** a configuration file supplies an `attachment_routing` sub-key that is not one of the six recognised names
- **THEN** the workflow SHALL report that sub-key as unrecognised and SHALL continue using the built-in default for every recognised sub-key the user did not supply


### Requirement: Attachment routing classifies user-written lists before retained defaults

This requirement supersedes the base-spec item "Attachment routing follows config-keyword-extension precedence".

The archive-mail workflow SHALL classify each attachment in two passes. The first pass SHALL use only the lists the user wrote in `attachment_routing` (including lists written as empty); the second pass SHALL use only the lists that kept their built-in defaults. Within each pass, filename keyword match SHALL be evaluated before extension match, and data before document. An attachment matched by neither pass SHALL be classified as document. When `attachment_routing` is absent the first pass is empty, and when all four lists are written the second pass is empty; in both cases the result SHALL equal the behaviour before this change.

#### Scenario: A user-written list is not defeated by a retained default

- **WHEN** a configuration file sets only `document_extensions` to a list containing `xlsx`
- **THEN** an attachment named `budget.xlsx` SHALL be classified as a document, even though the retained default `data_extensions` also contains `xlsx`

#### Scenario: A partial configuration keeps its previous result for files it matches

- **WHEN** a configuration file sets only `data_extensions` to a list containing `csv` and `data_keywords` to a list containing `raw`
- **THEN** an attachment named `responses_v2.csv` SHALL be classified as data by the first pass, and the retained default `document_keywords` entry `v2` SHALL NOT change that result

### Requirement: Partial routing configuration keeps unmentioned defaults

This requirement supersedes the partial-configuration rule of the base-spec item "Default routing rules when config is absent" (the archived scenario "Partial config replaces ALL defaults (no merge)").

When `attachment_routing` is absent from the configuration file, the workflow SHALL apply every built-in default. When it is present, each of `data_extensions`, `document_extensions`, `data_keywords`, and `document_keywords` that the user does not mention SHALL keep its built-in default, and `data_dir` and `documents_dir` SHALL keep their defaults when not mentioned. The earlier rule that a partial configuration replaces all four default lists with empty lists no longer applies.

#### Scenario: Absent configuration uses all defaults

- **WHEN** the configuration file has no `attachment_routing` key
- **THEN** all six sub-keys SHALL take their built-in default values

#### Scenario: Partial configuration keeps unmentioned defaults

- **WHEN** the configuration file supplies `attachment_routing` with only `data_extensions` and `data_keywords`
- **THEN** `document_extensions` and `document_keywords` SHALL keep their built-in defaults rather than becoming empty
