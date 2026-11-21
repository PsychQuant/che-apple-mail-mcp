import Foundation

/// The two command-line modes of direct transport (#742). They exist so that
/// the password and the "forget an unknown send" decision never pass through
/// an MCP tool: a person runs them in a terminal.
///
/// Both are pure over their inputs so the tests drive them without a keychain
/// or a terminal; `main.swift` supplies standard input and the keychain.
enum DirectTransportCLI {
    struct Outcome: Equatable {
        let status: Int32
        let message: String
    }

    /// `--direct-transport-set-credential <address>`: reads the password and
    /// creates or replaces the keychain item. The password is never printed.
    static func setCredential(address: String, readPassword: () -> String?,
                              store: (String, String) throws -> Void) -> Outcome {
        guard address.contains("@"), !address.contains(where: \.isWhitespace) else {
            return Outcome(status: 64, message: "--direct-transport-set-credential needs the account's address, as in direct-transport.json")
        }
        guard let raw = readPassword() else {
            return Outcome(status: 66, message: "no password was read from standard input; nothing was stored")
        }
        let password = stripLineEnd(raw)
        guard !password.isEmpty else {
            return Outcome(status: 65, message: "the password is empty; nothing was stored")
        }
        guard !password.contains(where: \.isNewline) else {
            return Outcome(status: 65, message: "the password spans more than one line; nothing was stored")
        }
        do {
            try store(address, password)
        } catch {
            return Outcome(status: 74, message: "\(error)")
        }
        return Outcome(status: 0, message: "stored the direct-transport credential for \(address) (keychain service \(DirectTransportCredential.service))")
    }

    /// `--direct-transport-forget <message-id>`: removes an entry whose send
    /// state is unknown, after the person has checked whether it was sent.
    /// A submitted entry is refused: removing it would let the same draft be
    /// submitted a second time.
    static func forget(messageID: String, records: SendRecordStore) -> Outcome {
        guard let messageID = SwiftMailSession.canonicalMessageID(messageID) else {
            return Outcome(status: 64, message: "--direct-transport-forget needs the Message-ID the result named, such as '<id@example.com>'")
        }
        do {
            switch try records.forgetUnknown(messageID) {
            case .removed:
                return Outcome(status: 0, message: "removed the unknown entry for \(messageID); a later send_draft call may submit that draft again")
            case .submitted:
                return Outcome(status: 1, message: "the entry for \(messageID) records a submission the server accepted; it is kept, so the draft cannot be submitted twice")
            case .absent:
                return Outcome(status: 1, message: "no entry for \(messageID) in the record of sent drafts; nothing was removed")
            case .inProgress:
                return Outcome(status: 75, message: "a send_draft call is running, so the entry may belong to a submission in progress; nothing was removed. Try again when it has finished")
            }
        } catch {
            return Outcome(status: 74, message: "the record of sent drafts could not be read or written (\(error)); nothing was removed")
        }
    }

    /// The forget command for a person to paste, with the Message-ID in POSIX
    /// single quotes (each `'` written as `'\''`). The Message-ID comes from the
    /// draft, which anyone can write, so it must not be able to leave its quotes.
    /// Nil when it holds a control character: no command is printed then.
    static func forgetCommand(for messageID: String) -> String? {
        guard !messageID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return nil
        }
        return "--direct-transport-forget '" + messageID.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// How to clear an unknown entry, as a sentence for a result or a refusal.
    static func forgetInstruction(for messageID: String) -> String {
        if let command = forgetCommand(for: messageID) {
            return "clear the entry by running the server binary with `\(command)`"
        }
        return "clear the entry for this Message-ID from direct-transport-sent.json by hand (it holds a control character, so no command is printed)"
    }

    /// One trailing CRLF, LF or CR, as a terminal or `printf '%s\n'` leaves it.
    /// A CRLF is a single `Character` in Swift, so one `dropLast()` removes it.
    private static func stripLineEnd(_ text: String) -> String {
        guard let last = text.last, last.isNewline else { return text }
        return String(text.dropLast())
    }

    /// Standard input as the password: with echo turned off when it is a
    /// terminal, otherwise the first line of what was piped in.
    static func readPasswordFromStandardInput() -> String? {
        if isatty(STDIN_FILENO) == 1 {
            var buffer = [CChar](repeating: 0, count: 1024)
            defer { buffer.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress, 0, $0.count) } }
            guard readpassphrase("Password (not shown): ", &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
        guard let line = readLine(strippingNewline: false) else { return nil }
        return line
    }
}
