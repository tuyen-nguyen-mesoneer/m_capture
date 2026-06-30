// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit
import Vision

/// Wraps Apple's Vision recognizers. Off the main thread, it reads a region for
/// both a QR/barcode payload and recognized text, preferring a decoded code when
/// present, and returns the result on the main thread. No external dependencies —
/// Vision is a system framework.
enum TextRecognizer {
    /// What was found in the region.
    enum Result {
        case code(String)
        case text(String)
        case none
    }

    static func recognize(_ cgImage: CGImage, completion: @escaping (Result) -> Void) {
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        let codeReq = VNDetectBarcodesRequest()

        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([codeReq, textReq])

            let codes = codeReq.results?.compactMap { $0.payloadStringValue } ?? []
            let lines = textReq.results?.compactMap { $0.topCandidates(1).first?.string } ?? []

            let result: Result
            if !codes.isEmpty {
                result = .code(codes.joined(separator: "\n"))
            } else if !lines.isEmpty {
                result = .text(lines.joined(separator: "\n"))
            } else {
                result = .none
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

