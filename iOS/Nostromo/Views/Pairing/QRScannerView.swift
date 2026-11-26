// Nostromo iOS — QRScannerView.swift
//
// The in-app scanner. The camera permission is requested on first appearance only (never before
// Scan Code). Denied: a message and a button to Enter Code Instead (PRD-AC2). A QR that is not a
// `nostromo://pair` link is ignored with an inline hint.

import SwiftUI
import AVFoundation
import NostromoKit

struct QRScannerView: View {
    let onLink: (PairLink) -> Void
    let onEnterCode: () -> Void

    @State private var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var hint: String?

    var body: some View {
        Group {
            switch permission {
            case .authorized:
                ZStack(alignment: .bottom) {
                    ScannerRepresentable(onCode: handle(code:)).ignoresSafeArea()
                    VStack(spacing: 12) {
                        if let hint {
                            Text(hint).padding(8).background(.thinMaterial, in: Capsule())
                        }
                        Button("Enter Code Instead", action: onEnterCode)
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.bottom, 32)
                }
            case .notDetermined:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
                VStack(spacing: 16) {
                    Text("Nostromo needs the camera to scan the pairing code. You can type the code instead.")
                        .multilineTextAlignment(.center)
                    Button("Enter Code Instead", action: onEnterCode)
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
            }
        }
        .navigationTitle("Scan Code")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if permission == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                permission = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func handle(code: String) {
        guard let url = URL(string: code), url.scheme?.lowercased() == "nostromo" else {
            hint = "That isn't a Nostromo pairing code."
            return
        }
        switch PairLink.parse(url) {
        case .success(let link): onLink(link)
        case .failure: hint = "That isn't a valid Nostromo pairing code."
        }
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

private final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastCode: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
              code != lastCode else { return }
        lastCode = code
        onCode?(code)
    }
}
