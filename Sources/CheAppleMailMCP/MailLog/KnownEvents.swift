import Foundation

/// #465 — the closed allowlist of events whose `formatString` carries no
/// literal text, so the template alone cannot name them.
///
/// **Exactly one entry.** The list is closed on purpose: adding a second means
/// a new change, not "something that looks like the first". The one entry is
/// the IMAP upload receipt, which is what answers "did the upload happen" for
/// the #463 chain.
///
/// The match is on the *shape of the response code*, not on the word. IMAP
/// FETCH responses echo mail content (a subject, say) into the same log
/// category, and a subject containing "APPENDUID" must not read as a receipt:
/// this tool exists to tell a caller whether an upload happened, and a forged
/// receipt would be worse than none.
///
/// **The shape is the one Mail actually logs**, not the RFC 3501 wire form. The
/// first version of this matcher followed the RFC (`[APPENDUID 1695 902]`),
/// passed every test written against synthetic fixtures in that form, and found
/// nothing in the real log: Mail prints the parsed code as an array description,
/// numbers separated by commas and line breaks (`[APPENDUID (⏎    n,⏎    n⏎)]`).
/// Only digits, commas and whitespace may sit inside the parentheses.
enum KnownEvents {
    static let appendUIDReceived = "imap.append_uid_received"

    /// Anchored at the line's OWN `Read: `: the one right after Mail's connection header
    /// `[server] <connection id:[Mailbox name=…]> `, or at the very start when there is no header.
    /// The header ends at the first `]> ` — real mailbox names contain `<` and `>` (653 of 88,636
    /// Read lines in eight hours), and every real Read line measured has this header.
    ///
    /// Why so strict: the text after the header is the server's response, and a FETCH echoes mail
    /// content into it; a Write line echoes what Mail sends, which can quote a received mail
    /// (verify round 2, finding 7 — the round-1 rule took the first `Read: ` anywhere). The tag
    /// must not be `*`: an untagged response is not the receipt of OUR append. The cost: a receipt
    /// that Mail logged in the same chunk AFTER an untagged response is missed (`unstructured`,
    /// never forged); 2 of 2 receipts in eight hours were first in their chunk. A mailbox NAME sits
    /// inside the header and is chosen by the folder's owner — that residual is the owner's, not an
    /// arbitrary sender's.
    ///
    /// The receipt must also be the WHOLE chunk, and its tag the shape Mail's tags have (digits and dots,
    /// at most 16 characters). A FETCH literal can be split across reads, so a continuation chunk starts
    /// with the sender's bytes right after the header and `Read: ` (verify round 3, findings 4/6). All 27
    /// receipts in 40 hours of real log had a `n.n` tag and nothing after `)]`.
    private static let taggedOKReceipt = try! NSRegularExpression(
        pattern: #"\A(?=[0-9.]{1,16} )[0-9]+(?:\.[0-9]+)* OK \[APPENDUID \(\s*[0-9]+\s*(?:,\s*[0-9]+\s*)+\)\]\s*\z"#)

    static func name(for event: MailLogEvent) -> String? {
        guard event.category == "IMAPConnection",
              !TemplateExtractor.hasLiteralText(event.formatString),
              let response = ownReadResponse(event.message).map(String.init) else { return nil }
        let range = NSRange(response.startIndex..., in: response)
        return taggedOKReceipt.firstMatch(in: response, range: range) != nil ? appendUIDReceived : nil
    }

    /// The text after the line's own `Read: `, or nil when the line is not a Read line.
    private static func ownReadResponse(_ message: String) -> Substring? {
        let read = "Read: "
        if message.hasPrefix(read) { return message.dropFirst(read.count) }
        guard message.hasPrefix("["),
              let serverEnd = message.range(of: "] <"),
              !message[..<serverEnd.lowerBound].contains(where: \.isNewline),
              let headerEnd = message.range(of: "]> ", range: serverEnd.upperBound..<message.endIndex),
              !message[serverEnd.upperBound..<headerEnd.lowerBound].contains(where: \.isNewline) else { return nil }
        let after = message[headerEnd.upperBound...]
        return after.hasPrefix(read) ? after.dropFirst(read.count) : nil
    }
}
