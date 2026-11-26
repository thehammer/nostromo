import XCTest
import CoreImage

// The pairing QR must scan back to exactly the URL the phone is meant to open.
final class PairQRTests: XCTestCase {

    private func scan(_ image: CGImage) -> [String] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    func testThePairingUrlIsWhatAScannerReadsBack() throws {
        let url = "nostromo://pair?v=1&host=h&port=7&code=123456"
        let image = try XCTUnwrap(PairQR.cgImage(for: url))
        XCTAssertEqual(scan(image), [url])
    }

    func testAnotherUrlReadsBackAsItself() throws {
        let url = "nostromo://pair?v=1&host=sendai.local&port=7443&code=004217"
        let image = try XCTUnwrap(PairQR.cgImage(for: url))
        XCTAssertEqual(scan(image), [url])
    }
}
