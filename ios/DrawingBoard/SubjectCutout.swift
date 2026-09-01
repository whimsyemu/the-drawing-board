import Foundation
import WebKit
import UIKit
import Vision
import CoreImage

/// Canva-style "magic grab": the page hands us a photo, we lift the subject
/// off its background with Apple's on-device Vision model, and hand back a
/// transparent PNG. Nothing leaves the device.
final class SubjectCutout: NSObject, WKScriptMessageHandler {

    static let handlerName = "cutout"

    private weak var webView: WKWebView?

    init(webView: WKWebView) {
        self.webView = webView
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let id = body["id"] as? String else { return }
        guard let dataURL = body["data"] as? String,
              let comma = dataURL.range(of: ","),
              let data = Data(base64Encoded: String(dataURL[comma.upperBound...])),
              let ui = UIImage(data: data),
              let cg = ui.cgImage else {
            reply(id: id, png: nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var out: String?
            if #available(iOS 17.0, *) {
                let request = VNGenerateForegroundInstanceMaskRequest()
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do {
                    try handler.perform([request])
                    if let result = request.results?.first, !result.allInstances.isEmpty {
                        let buffer = try result.generateMaskedImage(
                            ofInstances: result.allInstances,
                            from: handler,
                            croppedToInstancesExtent: true)
                        let ci = CIImage(cvPixelBuffer: buffer)
                        let context = CIContext()
                        if let cgOut = context.createCGImage(ci, from: ci.extent),
                           let png = UIImage(cgImage: cgOut).pngData() {
                            out = "data:image/png;base64," + png.base64EncodedString()
                        }
                    }
                } catch {
                    out = nil
                }
            }
            DispatchQueue.main.async { self?.reply(id: id, png: out) }
        }
    }

    private func reply(id: String, png: String?) {
        let pngLiteral = png.map { jsString($0) } ?? "null"
        let js = "window.__cutoutResult && window.__cutoutResult(\(jsString(id)), \(pngLiteral));"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
