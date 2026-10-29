# Native constructor binding investigation

Refs #409. This records one controlled experiment on macOS 27.0 / Mail 16.0
(2026-09-17). It does not implement a creation adapter or establish that all
possible public API routes are unavailable.

The installed `Mail.sdef` defines two different classes and backing keys:

| Public class/property | Cocoa backing key |
| --- | --- |
| `outgoing message.id` | `uniqueID` |
| stored `message.id` | `libraryID` |

The outgoing class does not inherit `message` in the dictionary. Its advertised
properties do not include the stored message's `mailbox` or `message id`.
The imported Cocoa Standard `save` declaration has no result declaration.
Different backing keys alone do not prove numeric inequality, but they do not
provide an equivalence contract either.

## Controlled observations

One hidden outgoing message was created with a new UUID subject and exactly one
`fixture@example.invalid` recipient. No `content` or `html content` assignment
was made, and no send command was issued. The saved fixture was inspected only
through its unique synthetic UUID; that test lookup must not be promoted into
production subject-based creation binding.

| Probe | Observed result |
| --- | --- |
| Create outgoing, then save | A native outgoing handle and one saved Drafts record existed |
| Compare IDs | Outgoing ID differed from the saved record's library ID |
| Assign the `save` result and inspect it | Save returned, but reading the assigned variable raised `-2753`; no usable result object was captured |
| Read `message id` through outgoing handle | `-1700` |
| Read outgoing mailbox/account | `-1700` |
| Save the same outgoing handle to a new owned file path | Command returned; no file appeared at that path in immediate or later checks |
| Request `visible=true` after save | Subsequent visibility remained false and no UUID-matching window was observed |
| Read `window.document` | Not exercised: no matching window was available |

These observations rule out treating this outgoing ID as the saved row ID, and
do not validate a bridge through the tested getters or save result. They do not
prove that `window.document` is unavailable on an actual mailto compose window.
That remains a separate candidate requiring a controlled, owned-window probe.
The empty message also provides no evidence about wrapper-free insertion of a
nonempty caller body; a redesigned creation route would need that evidence.

## Cleanup and remaining artifact

A close with `saving no` returned successfully but left the hidden handle in the
scripting collection. The saved draft was then freshly checked by actual
account, row ID, Message-ID, UUID subject, single fixture recipient, and complete
normalized source bytes before moving that exact message to Trash.

Final native counts for this UUID were:

| Surface | Count |
| --- | ---: |
| Matching windows | 0 |
| Drafts records | 0 |
| Outbox records | 0 |
| Account Trash records | 1 |
| Outgoing scripting handles | 1 |

The message remains recoverable in Trash. The retained scripting handle is not
claimed to be cleaned up. The user has been asked whether to restart Mail
manually or retain it; no automatic restart or further deletion was performed.
After any restart, query the UUID again rather than reuse the old numeric handle
ID, which belongs to the earlier Mail process lifetime.

No production adapter was selected, no same-subject update was demonstrated,
and #409's original live and integration requirements remain open.
