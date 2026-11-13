import AVFoundation
import Foundation

/// Один кадр с камеры по явному запросу. Session живёт только на время кадра.
@MainActor
final class CameraCapturer: NSObject, @preconcurrency AVCapturePhotoCaptureDelegate {
    static let shared = CameraCapturer()

    private var session: AVCaptureSession?
    private var continuation: CheckedContinuation<URL, Error>?

    func capture() async throws -> URL {
        try await ensurePermission()
        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "SolarCamera", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "камера на Mac не найдена"])
        }

        let session = AVCaptureSession()
        session.sessionPreset = .photo
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "SolarCamera", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось подключить камеру"])
        }
        session.addInput(input)
        let output = AVCapturePhotoOutput()
        guard session.canAddOutput(output) else {
            throw NSError(domain: "SolarCamera", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось получить кадр с камеры"])
        }
        session.addOutput(output)
        self.session = session
        session.startRunning()

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        session?.stopRunning()
        session = nil
        let callback = continuation
        continuation = nil
        if let error {
            callback?.resume(throwing: error)
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            callback?.resume(throwing: NSError(domain: "SolarCamera", code: 4,
                                                userInfo: [NSLocalizedDescriptionKey: "камера вернула пустой кадр"]))
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SolarCopilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("camera.jpg")
        do {
            try data.write(to: url, options: .atomic)
            callback?.resume(returning: url)
        } catch {
            callback?.resume(throwing: error)
        }
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            let allowed = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { continuation.resume(returning: $0) }
            }
            if allowed { return }
            fallthrough
        case .denied, .restricted:
            throw NSError(domain: "SolarCamera", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "разреши камеру для Solar Copilot в Системных настройках → Конфиденциальность и безопасность → Камера"])
        @unknown default:
            throw NSError(domain: "SolarCamera", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "macOS не дала доступ к камере"])
        }
    }
}
