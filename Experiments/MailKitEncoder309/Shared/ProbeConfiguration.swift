import Foundation
import MailKit

/// Throwaway #309 probe. Empty build settings deliberately disable all matches.
struct ProbeConfiguration {
    let recipient: String
    let runID: String
    var subject: String { "IDD309-" + runID }
    var originalMarker: String { "IDD309_ORIGINAL_" + runID }
    var replacementMarker: String { "IDD309_REPLACED_" + runID }

    init?(recipient: String, runID: String) {
        guard let uuid = UUID(uuidString: runID),
              !recipient.isEmpty,
              recipient.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }),
              MEEmailAddress(rawString: recipient).addressString == recipient,
              recipient.filter({ $0 == "@" }).count == 1 else { return nil }
        self.recipient = recipient
        self.runID = uuid.uuidString
    }

    func matches(subject: String, sender: String?, recipients: [String?]) -> Bool {
        subject == self.subject && sender == recipient && recipients.count == 1
            && recipients[0] == recipient
    }

    /// Only a single 7-bit text/plain message is supported by this probe.
    /// Multipart, attachments, encoded transfer forms and signing headers refuse.
    func replacement(in raw: Data) -> Data? {
        guard raw.count <= 1_048_576,
              let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<separator.lowerBound)
        guard let headers = String(data: headerData, encoding: .ascii),
              acceptsPlainHeaders(headers) else { return nil }
        let body = raw.subdata(in: separator.upperBound..<raw.endIndex)
        guard body.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else { return nil }
        let marker = Data(originalMarker.utf8)
        guard let first = body.range(of: marker),
              body.range(of: marker, in: first.upperBound..<body.endIndex) == nil else { return nil }
        var output = raw.subdata(in: raw.startIndex..<separator.upperBound)
        output.append(body.subdata(in: body.startIndex..<first.lowerBound))
        output.append(Data(replacementMarker.utf8))
        output.append(body.subdata(in: first.upperBound..<body.endIndex))
        return output
    }

    private func acceptsPlainHeaders(_ text: String) -> Bool {
        var fields: [String: String] = [:]
        var lastName: String?
        for line in text.components(separatedBy: "\r\n") {
            guard line.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else { return false }
            if line.first == " " || line.first == "\t" {
                guard let name = lastName else { return false }
                fields[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (33...57).contains($0) || (59...126).contains($0) }),
                  fields[name] == nil else { return false }
            fields[name] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            lastName = name
        }
        guard let contentType = fields["content-type"]?.lowercased(),
              fields["content-transfer-encoding", default: "7bit"].lowercased() == "7bit",
              fields["mime-version", default: "1.0"] == "1.0",
              fields["dkim-signature"] == nil, fields["arc-seal"] == nil,
              fields["arc-message-signature"] == nil else { return false }
        guard fields.keys.filter({ $0.hasPrefix("content-") }).allSatisfy({
            $0 == "content-type" || $0 == "content-transfer-encoding"
        }) else { return false }
        let parts = contentType.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first == "text/plain", parts.count <= 2 else { return false }
        if parts.count == 2 {
            let parameter = parts[1].components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parameter.count == 2, parameter[0] == "charset",
                  ["utf-8", "us-ascii", "\"utf-8\"", "\"us-ascii\""].contains(parameter[1]) else { return false }
        }
        return true
    }

}
