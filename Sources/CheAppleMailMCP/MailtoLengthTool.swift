import MCP

let checkComposeLengthTool = Tool(
    name: "check_compose_length",
    description: "Read-only exact mailto length preflight for the GUI (mailto) path of compose_email/create_draft/update_draft; create_draft's opt-in direct write has no such limit. Counts UTF-8 percent-encoding and the same recipient partition (display-name lists use GUI instead of URL). Returns encoded_url_length, body_encoded_length, other_encoded_length, limit=8000, remaining, fits and other_requirements_checked=false. Does not access Mail or build the encoded URL. fits=true does not validate addresses, format, permissions, sender, attachments or signature selection. Over the limit on the GUI path: create a short or empty-body draft and manually paste the full body in Mail (keep it where the user chooses), or use separately approved smaller messages; do not truncate (AppleScript body injection was removed, #304).",
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
