import MCP

let checkComposeLengthTool = Tool(
    name: "check_compose_length",
    description: "Read-only exact mailto length preflight for compose_email/create_draft/update_draft. Counts UTF-8 percent-encoding and the same recipient partition (display-name lists use GUI instead of URL). Returns encoded_url_length, body_encoded_length, other_encoded_length, limit=8000, remaining, fits and other_requirements_checked=false. Does not access Mail or build the encoded URL. fits=true does not validate addresses, format, permissions, sender, attachments or signature selection. Over-limit calls should use a local text file and manual paste in Mail, or separately approved smaller messages; do not truncate or use a removed legacy fallback.",
    inputSchema: .object([
        "type": .string("object"), "additionalProperties": .bool(false),
        "properties": .object([
            "to": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "cc": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "bcc": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "subject": .object(["type": .string("string")]), "body": .object(["type": .string("string")])
        ]), "required": .array([.string("to"), .string("subject"), .string("body")])
    ]), annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
)
