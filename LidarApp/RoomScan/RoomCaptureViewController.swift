import UIKit
import RoomPlan

/// Kontroler UIKit opakowujący RoomCaptureView (RoomPlan).
/// UIViewController już implementuje NSCoding, którego wymaga RoomCaptureViewDelegate.
final class RoomCaptureViewController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {

    var onFinished: ((CapturedRoom) -> Void)?
    var onError: ((Error) -> Void)?

    private var roomCaptureView: RoomCaptureView!
    private let sessionConfig = RoomCaptureSession.Configuration()
    private var isRunning = false

    override func viewDidLoad() {
        super.viewDidLoad()
        roomCaptureView = RoomCaptureView(frame: view.bounds)
        roomCaptureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        roomCaptureView.captureSession.delegate = self
        roomCaptureView.delegate = self
        view.addSubview(roomCaptureView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCapture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopCapture()
    }

    func startCapture() {
        guard !isRunning else { return }
        isRunning = true
        roomCaptureView.captureSession.run(configuration: sessionConfig)
    }

    /// Kończy skanowanie – RoomPlan przetworzy dane i wywoła captureView(didPresent:error:).
    func stopCapture() {
        guard isRunning else { return }
        isRunning = false
        roomCaptureView.captureSession.stop()
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        if let error {
            onError?(error)
            return
        }
        onFinished?(processedResult)
    }
}
