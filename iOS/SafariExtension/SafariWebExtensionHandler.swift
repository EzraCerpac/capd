import CapdMobile
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        do {
            guard context.inputItems.count == 1,
                let item = context.inputItems.first as? NSExtensionItem,
                let message = item.userInfo?[SFExtensionMessageKey]
            else { throw SafariCaptureError.invalidMessage }
            let request = try SafariCaptureRequest(message: message)
            _ = try MobileEnvironment.session(role: .shareExtension).save(request.capture)
            response.userInfo = [SFExtensionMessageKey: ["status": "saved"]]
        } catch {
            response.userInfo = [SFExtensionMessageKey: ["status": "error"]]
        }
        context.completeRequest(returningItems: [response])
    }
}
