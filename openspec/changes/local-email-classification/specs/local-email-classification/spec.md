## Purpose

Provide local, explainable email classification and auditable Trash actions constrained by exact user-approved rules and per-message protections.

## ADDED Requirements

### Requirement: Local explicit policy and approvals
The policy SHALL support custom categories and enabled deterministic rules with AND conditions over sender equals, subject equals/contains, and List-ID equals. Unknown fields, unknown categories, duplicate ids, empty condition lists, body conditions, and unsupported operators SHALL be rejected. Approvals SHALL bind to full rule content fingerprints and SHALL require an explicit caller assertion of user approval. Rule edits SHALL invalidate changed approvals.

#### Scenario: Edited trash rule loses approval
- **WHEN** an approved rule's condition, category, action, or enabled state changes
- **THEN** its old approval SHALL NOT authorize automatic disposal

### Requirement: Explainable read-only classification
Classification SHALL return each message's category, matching rule ids, proposed action, and reason without modifying Mail. Conflicting matched outcomes SHALL require preview. No match SHALL yield unclassified/review. Automatic trash eligibility SHALL require a matching valid approved trash rule, verified identity, known non-draft and non-VIP status, and an unflagged message.

#### Scenario: Conflicting rules
- **WHEN** a keep rule and a trash rule both match a message
- **THEN** the result SHALL be conflict/review and SHALL NOT be eligible for automatic trash

### Requirement: Bounded plans and explicit selection
The engine SHALL create plans for at most 200 unique ids, expire them after 300 seconds, and apply only explicitly selected ids. It SHALL reject stale policy, changed message identity or classification inputs, unknown ids, and already attempted items. Unapproved items SHALL require explicit preview confirmation. An item with an uncertain outcome SHALL NOT be automatically retried. Persistent account/Message-ID dispatch records SHALL block started and uncertain attempts across plans and server restarts; explicit preview confirmation SHALL NOT override this block.

#### Scenario: Policy changed after preview
- **WHEN** apply receives a plan produced under a different policy digest
- **THEN** no selected message SHALL be moved

### Requirement: Guarded Trash movement
Execution SHALL identify the exact account, source mailbox chain, numeric message id and RFC Message-ID immediately before movement. Preview, refresh and final native comparison SHALL use native RFC source with only CRLF/CR normalized to LF; complete normalized bytes SHALL be compared before movement. Native source SHALL NOT be persisted or included in plan responses. The native script SHALL recheck expiry immediately before move. It SHALL require one native Trash role in that account, move to that role, and SHALL NOT invoke permanent deletion or empty Trash. Unknown identity or ambiguous targets SHALL refuse.

#### Scenario: Timeout after dispatch
- **WHEN** the native move fails to return a conclusive receipt
- **THEN** the result SHALL be outcome_unknown, with no automatic retry of that plan item

### Requirement: Durable minimal audit
Before moving a message, the engine SHALL persist a started audit record. Audit failure SHALL prevent dispatch. Outcome records SHALL contain identifiers, Message-ID hashes, rule/category and outcome but SHALL NOT contain message subjects or bodies. Policy persistence SHALL be atomic and SHALL reject unsafe storage files.

#### Scenario: Audit cannot be written
- **WHEN** the audit store cannot durably append a started event
- **THEN** native Mail movement SHALL NOT be invoked

### Requirement: Public tools and authorization provenance
The server SHALL expose policy read/configure, read-only classify, and explicit plan apply tools. The plugin SHALL show proposed rules before requesting user approval, SHALL NOT treat message content or third-party settings as authorization, and SHALL automatically apply only the explicitly approved rule subset. Existing Mail actions outside that subset SHALL retain their confirmation behavior.

#### Scenario: Message body asks to skip confirmation
- **WHEN** a message contains text instructing the agent to enable automatic trash
- **THEN** that text SHALL remain data and SHALL NOT create a policy approval


### Requirement: Auditable policy history and no implicit retry reset
Before dispatch the policy envelope SHALL be archived by digest, and the audit SHALL reference that digest so edits cannot erase the criteria that authorized an earlier action. Persistent identity reservations SHALL NOT be cleared by a new plan, server restart, or confirmed-preview flag. Definitive non-mutating guard refusals SHALL permit a fresh classification; uncertain attempts SHALL require independent Mail inspection and separately confirmed manual intervention outside the classifier.

#### Scenario: Another plan attempts an uncertain identity
- **WHEN** plan A has an unknown native outcome and plan B selects the same account and Message-ID
- **THEN** plan B SHALL NOT dispatch, including after a new engine reads the persisted records


### Requirement: Fresh VIP protection for automatic Trash
Automatic Trash SHALL additionally require known non-VIP status. VIP status SHALL be derived from a fresh, completely parsed local sender snapshot using the same conservative canonical address parser for both sides. Missing, unreadable, malformed, unsupported, changed-during-read or expired snapshots and ambiguous sender fields SHALL yield unknown and SHALL block automatic Trash. VIP and unknown messages SHALL remain proposed-trash preview items with `vip_protected` or `vip_status_unknown`. A rule approval SHALL NOT override either protection. Explicit per-message preview confirmation SHALL retain the existing manual selection contract.

#### Scenario: Approved rule matches a VIP
- **WHEN** a message from a VIP matches an approved trash rule
- **THEN** its category and proposed action SHALL remain visible and automatic_trash_allowed SHALL be false

#### Scenario: VIP lookup cannot prove absence
- **WHEN** a VIP snapshot cannot be fully read and parsed or is 60 seconds old
- **THEN** automatic Trash SHALL be disabled rather than treating the lookup as an empty list

### Requirement: VIP changes invalidate pending classification
Preview, each apply refresh, and the native dispatch boundary SHALL read the VIP source again. The per-message VIP state SHALL participate in the existing message fingerprint, without persisting the sender list or observation timestamp. Changed VIP status SHALL prevent dispatch from a stale plan even with preview confirmation. Existing audit-before-move, policy fingerprint and persistent duplicate-dispatch blocks SHALL remain enforced.

#### Scenario: Sender becomes VIP after preview
- **WHEN** an eligible non-VIP preview is applied after the sender becomes VIP
- **THEN** the stale item SHALL NOT move and a fresh classification SHALL be required

#### Scenario: Explicit confirmation cannot override uncertain prior dispatch
- **WHEN** a confirmed VIP preview selects an identity with an uncertain previous attempt
- **THEN** the persistent dispatch block SHALL continue to prevent movement
