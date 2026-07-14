import Flutter
import UIKit

/// Reports whether protected data (and therefore the HealthKit store, which
/// is file-protected) is readable right now.
///
/// The HealthKit database is encrypted while the device is locked. A
/// `getHealthDataFromTypes` call made from a background task on a locked
/// device returns nothing, which the Dart sync loop previously could not
/// distinguish from "genuinely no new data" — it reported the run as a
/// successful "Already up to date" sync. The Dart side calls this before
/// reading HealthKit and converts an unreadable store into a retryable
/// failure instead.
///
/// Channel: com.tikcare.vitametric/devicelock
/// Method:  isProtectedDataAvailable() → Bool
final class DeviceLockChannel: NSObject {
    private static let channelName = "com.tikcare.vitametric/devicelock"

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            guard call.method == "isProtectedDataAvailable" else {
                result(FlutterMethodNotImplemented)
                return
            }
            // UIApplication must be touched on the main thread; background
            // isolates deliver platform calls on a background queue.
            DispatchQueue.main.async {
                result(UIApplication.shared.isProtectedDataAvailable)
            }
        }
    }
}
