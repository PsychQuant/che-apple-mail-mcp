## REMOVED Requirements

### Requirement: A failed recording moves nothing

**Reason**: The maintainer decided on 2026-11-13 that an answer given in the conversation still applies when only the write of the record fails; the requirement is replaced by one that states both cases.

**Migration**: See the requirement 'An answer that could not be stored still applies to the run that asked'. Its second half keeps the earlier rule for every recording error other than a failed write.

## ADDED Requirements

### Requirement: An answer that could not be stored still applies to the run that asked

When recording the answer fails only at the write (`junk-decisions-write-failed`: the record could be read and could not be written), the rescue step SHALL still act on the answer the user gave in this conversation: it SHALL compute the plan again with that answer supplied as this run's answers, SHALL move the mail of the plan's move group, and SHALL report that the answer was not recorded and that the question will be asked again. This run's answers SHALL decide only the senders they name, SHALL be ignored unless every one of them is a bare lower-case address with `rescue` or `leave`, and SHALL be ignored when nobody is present or the record has a read error. When recording returns any other error, the rescue step SHALL move no mail in that run, including mail from senders already recorded as `rescue`, SHALL list every mail of the plan it started with as listed only with the error name, and SHALL NOT compute the plan again. When the plan computed after recording names a sender that was not in the question, the step SHALL NOT ask a second time and SHALL only list that sender's mail. The step SHALL tell the user to delete an entry or move the file away, not to edit entries. When the junk mailbox check of the report did not run, the step SHALL NOT run and its task SHALL be closed with that reason.

#### Scenario: a yes still moves the mail when the record cannot be written

- **WHEN** the user answers the question with "move" and writing the record fails
- **THEN** the mail of the senders in the question is moved in that run and the report says the answer was not recorded

#### Scenario: an answer that could not be stored changes no mailbox when the record is unreadable

- **WHEN** recording returns a read error of the record
- **THEN** no call that changes the mailbox is made in that run

##### Example: plan with answers that could not be stored

Mails in the junk mailbox from `a@example.invalid`, `b@example.invalid` and `c@example.invalid`; the record has `c@example.invalid` decided as `leave`.

| This run's answers | Attended | Record error | move | leave | ask |
| ------------------ | -------- | ------------ | ---- | ----- | --- |
| `a` rescue, `b` leave | yes | none | a | b, c | (none) |
| `a` with the decision `maybe` | yes | none | (none) | c | a, b |
| `a` rescue | no | none | (none) | c | (none; a and b are listed only, nobody present) |
| `a` rescue | yes | `junk-decisions-not-json` | (none) | (none) | (none; all listed only) |

##### Example: rescue step text on a failed recording

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that on a recording error other than a failed write nothing is moved in that run including the move group, that the plan is not computed again, that a sender appearing only in the plan computed after recording is not asked about a second time, that the user deletes an entry or moves the file away, and how the task is closed when the report's check did not run

##### Example: rescue step text on an unrecorded answer

- **GIVEN** the Step 9 section of the archive-mail command
- **WHEN** its text is read
- **THEN** it states that when the write fails the user's consent in this conversation still holds, that the plan is computed again with the answers, and that the report says the answer was not recorded and will be asked again
