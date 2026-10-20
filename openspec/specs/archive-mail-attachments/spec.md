# archive-mail-attachments Specification

## Purpose

Defines how `/archive-mail` downloads attachment files from archived emails, where they are placed on disk (with data-vs-document routing), and how they are linked from the generated Markdown. Includes config schema, routing precedence, filename preservation, and cross-reference behavior for replies.

## Requirements

(Synced from change delta specs — see archived change for full scenario details with @trace comments.)

- Skill downloads attachments from archived emails
- Attachment directory matches email Markdown stem
- Attachment routing follows config-keyword-extension precedence
- Default routing rules when config is absent
- Filename preservation on disk with URL encoding in Markdown links only
- Attachment block placement in Markdown
- Reply without attachments emits cross-reference
- Skill output report summarizes attachment routing
