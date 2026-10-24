import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        // Handoffs use a visible user-tapped URL, not hidden native messaging.
        context.completeRequest(returningItems: nil)
    }
}
