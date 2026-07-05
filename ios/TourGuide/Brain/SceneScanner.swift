import Foundation
import Vision

/// On-device scan of a captured photo (free, instant, offline):
/// - QR / Aztec / DataMatrix codes → payloads (drive the QR fast path)
/// - product barcodes (EAN/UPC) + any readable text → hint for the brain
struct SceneScan {
    var qrPayloads: [String] = []
    var hintText: String = ""      // OCR'd signs/labels + product barcode numbers
}

enum SceneScanner {
    static func scan(_ imageData: Data) async -> SceneScan {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: scanSync(imageData))
            }
        }
    }

    private static func scanSync(_ imageData: Data) -> SceneScan {
        var result = SceneScan()
        let handler = VNImageRequestHandler(data: imageData)

        let barcodes = VNDetectBarcodesRequest()
        barcodes.symbologies = [.qr, .aztec, .dataMatrix, .ean13, .ean8, .upce, .code128]

        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true

        try? handler.perform([barcodes, text])

        var hints: [String] = []
        for code in barcodes.results ?? [] {
            guard let payload = code.payloadStringValue, !payload.isEmpty else { continue }
            switch code.symbology {
            case .qr, .aztec, .dataMatrix:
                result.qrPayloads.append(payload)
            default:
                hints.append("Product barcode: \(payload)")   // context only
            }
        }
        let lines = (text.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { $0.count > 1 }
        if !lines.isEmpty {
            hints.append(lines.joined(separator: "\n"))
        }
        result.hintText = String(hints.joined(separator: "\n").prefix(500))
        return result
    }
}
