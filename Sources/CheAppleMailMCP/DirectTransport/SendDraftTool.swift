import Foundation
import MCP

/// The `send_draft` tool (#742): argument checks, the configuration and the
/// credential, then `SendDraftFlow`. Everything outside the process comes in
/// through `Environment`, so the tests run it without a keychain or a network.
enum SendDraftTool {
    static let name = "send_draft"
    static let argumentNames: Set<String> = ["account_name", "account_id", "draft_id", "subject_match"]

    struct Environment {
        let stateDirectory: URL
        let password: (String) throws -> String?
        let openSession: (DirectTransportConfig.Account, String) async throws -> DirectTransportSession
        let localMessageID: (Int) throws -> String?
        let now: () -> Date
    }

    static func run(_ arguments: [String: Value], _ environment: Environment) async throws -> String {
        // The argument list is closed, so nothing a caller passes can write content,
        // and a misspelt argument is refused instead of ignored (#677).
        if let extra = arguments.keys.sorted().first(where: { !argumentNames.contains($0) }) {
            throw MailError.invalidParameter("send_draft does not accept '\(extra)'; it takes only account_name, account_id, draft_id and subject_match, and cannot write content")
        }
        let accountName = try stringArgument(arguments, "account_name")
        let accountID = try stringArgument(arguments, "account_id")
        let draftID = try stringArgument(arguments, "draft_id")
        let subject = try stringArgument(arguments, "subject_match")
        let selector: DraftSelector
        switch (draftID, subject) {
        case (let id?, nil):
            guard let row = Int(id), row > 0 else {
                throw MailError.invalidParameter("draft_id must be a numeric message id (got: '\(id)')")
            }
            selector = .localRow(row)
        case (nil, let text?):
            guard !text.isEmpty else { throw MailError.invalidParameter("subject_match must not be empty") }
            selector = .subject(text)
        default:
            throw MailError.invalidParameter("send_draft takes exactly one of draft_id and subject_match")
        }
        guard (accountName?.isEmpty == false) || (accountID?.isEmpty == false) else {
            throw MailError.invalidParameter("send_draft needs account_name or account_id")
        }

        let configURL = environment.stateDirectory.appendingPathComponent(DirectTransportConfig.fileName)
        let config: DirectTransportConfig
        do {
            guard let loaded = try DirectTransportConfig.load(from: configURL) else {
                throw MailError.operationFailed("direct transport is not configured: no \(DirectTransportConfig.fileName) in the server's state directory. Nothing was submitted, and no Mail path is used instead")
            }
            config = loaded
        } catch let problem as DirectTransportConfig.Problem {
            throw MailError.operationFailed("\(problem). Nothing was submitted")
        }
        guard let account = config.account(accountID: accountID, accountName: accountName) else {
            throw MailError.operationFailed("direct transport is not configured for \(accountID ?? accountName ?? "this account"). Nothing was submitted, and no Mail path is used instead")
        }
        let password: String
        do {
            guard let stored = try environment.password(account.address) else {
                throw MailError.operationFailed("no stored credential for \(account.address): run the server binary with `--direct-transport-set-credential \(account.address)` and type the app-specific password. Nothing was submitted")
            }
            password = stored
        } catch let failure as DirectTransportCredential.Failure {
            throw MailError.operationFailed("\(failure). Nothing was submitted")
        }

        let session: DirectTransportSession
        do {
            session = try await environment.openSession(account, password)
        } catch {
            throw MailError.operationFailed("\(error)")
        }
        let flow = SendDraftFlow(account: account, session: session,
                                 records: SendRecordStore(directory: environment.stateDirectory),
                                 localMessageID: environment.localMessageID, now: environment.now)
        let result: SendDraftResult
        do {
            result = try await flow.run(selector)
        } catch let refusal as SendDraftRefusal {
            await session.close()
            throw MailError.operationFailed(refusal.description)
        } catch {
            await session.close()
            throw MailError.operationFailed("send_draft stopped (\(error)); nothing more was done")
        }
        await session.close()
        return render(result)
    }

    static func render(_ result: SendDraftResult) -> String {
        var object: [String: Any] = [
            "outcome": result.outcome.rawValue,
            "message_id": result.messageID,
            "sent_copy": result.sentCopy.rawValue,
            "draft_removal": result.draftRemoval.rawValue,
            "resumed": result.resumed,
            "notes": result.notes,
        ]
        object["server_reply"] = result.serverReply ?? NSNull()
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// A string argument, nil when absent or JSON null; any other type is refused by name.
    private static func stringArgument(_ arguments: [String: Value], _ key: String) throws -> String? {
        guard let value = arguments[key] else { return nil }
        if case .null = value { return nil }
        guard case .string(let text) = value else {
            throw MailError.invalidParameter("'\(key)' must be a string")
        }
        return text
    }
}
