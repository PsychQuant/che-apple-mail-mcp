import Foundation
import MailKit
import OSLog

final class MailExtension: NSObject, MEExtension {
    func handlerForMessageSecurity() -> MEMessageSecurityHandler {
        ProbeSecurityHandler()
    }
}

final class ProbeSecurityHandler: NSObject, MEMessageSecurityHandler {
    private let log = Logger(subsystem: "org.psychquant.experimental.encoder309", category: "probe")
    private let configuration = ProbeConfiguration(
        recipient: Bundle.main.object(forInfoDictionaryKey: "ProbeRecipient") as? String ?? "",
        runID: Bundle.main.object(forInfoDictionaryKey: "ProbeRunID") as? String ?? ""
    )

    private func candidate(_ message: MEMessage) -> ProbeConfiguration? {
        guard message.ccAddresses.isEmpty, message.bccAddresses.isEmpty,
              message.toAddresses.count == 1, let c = configuration,
              c.matches(subject: message.subject, sender: message.fromAddress.addressString,
                        recipients: message.allRecipientAddresses.map(\.addressString)) else { return nil }
        return c
    }

    func getEncodingStatus(for message: MEMessage, composeContext: MEComposeContext,
                           completionHandler: @escaping (MEOutgoingMessageEncodingStatus) -> Void) {
        if candidate(message) != nil { log.notice("candidate-status") }
        // We do not possess a signing identity or encrypt anything.
        completionHandler(MEOutgoingMessageEncodingStatus(canSign: false, canEncrypt: false,
                                                          securityError: nil, addressesFailingEncryption: []))
    }

    func encode(_ message: MEMessage, composeContext: MEComposeContext,
                completionHandler: @escaping (MEMessageEncodingResult) -> Void) {
        guard let c = candidate(message) else {
            completionHandler(MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil))
            return
        }
        log.notice("candidate-encode-called")
        guard let raw = message.rawData else {
            log.notice("candidate-no-raw-data")
            completionHandler(MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil))
            return
        }
        guard let replacement = c.replacement(in: raw) else {
            log.notice("candidate-replacement-refused")
            completionHandler(MEMessageEncodingResult(encodedMessage: nil, signingError: nil, encryptionError: nil))
            return
        }
        // The SDK contract says Mail ignores this data. Only a host experiment
        // can establish its runtime behavior; constructing this object cannot.
        let encoded = MEEncodedOutgoingMessage(rawData: replacement, isSigned: false, isEncrypted: false)
        log.notice("returned-unsigned-replacement")
        completionHandler(MEMessageEncodingResult(encodedMessage: encoded, signingError: nil, encryptionError: nil))
    }

    func decodedMessage(forMessageData data: Data) -> MEDecodedMessage? { nil }
    func extensionViewController(signers messageSigners: [MEMessageSigner]) -> MEExtensionViewController? { nil }
    func extensionViewController(messageContext context: Data) -> MEExtensionViewController? { nil }
    func primaryActionClicked(forMessageContext context: Data,
                              completionHandler: @escaping (MEExtensionViewController?) -> Void) {
        completionHandler(nil)
    }
}
