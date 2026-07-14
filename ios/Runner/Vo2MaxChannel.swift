import Flutter
import HealthKit

/// Native HealthKit bridge for VO2_MAX (HKQuantityTypeIdentifierVO2Max).
/// The Flutter `health` package v13.x does not expose this quantity type, so
/// we query HealthKit directly and return samples via MethodChannel in the same
/// shape as _convertToMobileSyncEvent on the Dart side.
///
/// Channel: com.tikcare.vitametric/vo2max
/// Method:  readVo2Max({startMs: Int, endMs: Int}) → [[String: Any]]
final class Vo2MaxChannel: NSObject {
    private static let channelName = "com.tikcare.vitametric/vo2max"
    private static let store = HKHealthStore()
    // mL·kg⁻¹·min⁻¹ — the unit HealthKit stores VO2Max in.
    private static let vo2Unit = HKUnit(from: "ml/(kg·min)")

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "requestAuthorization":
                // Called from the FOREGROUND permission flow. VO2_MAX is not
                // in the health plugin's authorization list, so it was only
                // ever requested lazily inside readSamples — mid-sync, and
                // possibly from a headless background isolate where iOS
                // cannot present the permission sheet; authorization then
                // stayed undetermined and every read returned [] forever.
                requestAuthorization(flutterResult: result)
            case "readVo2Max":
                guard
                    let args = call.arguments as? [String: Any],
                    let startMs = args["startMs"] as? Int,
                    let endMs = args["endMs"] as? Int
                else {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "readVo2Max requires startMs and endMs (Int milliseconds)",
                        details: nil
                    ))
                    return
                }
                let start = Date(timeIntervalSince1970: Double(startMs) / 1_000.0)
                let end   = Date(timeIntervalSince1970: Double(endMs)   / 1_000.0)
                readSamples(start: start, end: end, flutterResult: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func requestAuthorization(flutterResult: @escaping FlutterResult) {
        guard
            HKHealthStore.isHealthDataAvailable(),
            let vo2Type = HKQuantityType.quantityType(forIdentifier: .vo2Max)
        else {
            flutterResult(false)
            return
        }
        store.requestAuthorization(toShare: nil, read: [vo2Type]) { success, _ in
            flutterResult(success)
        }
    }

    // MARK: - Private

    private static func readSamples(
        start: Date,
        end: Date,
        flutterResult: @escaping FlutterResult
    ) {
        guard
            HKHealthStore.isHealthDataAvailable(),
            let vo2Type = HKQuantityType.quantityType(forIdentifier: .vo2Max)
        else {
            flutterResult([])
            return
        }

        // Authorization is a no-op if already determined; never blocks.
        store.requestAuthorization(toShare: nil, read: [vo2Type]) { _, _ in
            let predicate = HKQuery.predicateForSamples(
                withStart: start,
                end: end,
                options: .strictStartDate
            )
            let sort = NSSortDescriptor(
                key: HKSampleSortIdentifierStartDate,
                ascending: true
            )
            let query = HKSampleQuery(
                sampleType: vo2Type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                guard error == nil, let samples = samples as? [HKQuantitySample] else {
                    flutterResult([])
                    return
                }

                let fmt = ISO8601DateFormatter()
                let events: [[String: Any]] = samples.compactMap { sample in
                    let value = sample.quantity.doubleValue(for: vo2Unit)
                    // Reject out-of-physiological-range values before sending.
                    guard value >= 10.0 && value <= 90.0 else { return nil }

                    let sourceBundle = sample.sourceRevision.source.bundleIdentifier
                    let algo: String
                    if sourceBundle.contains("apple") || sourceBundle.contains("com.apple") {
                        algo = "AppleWatch_VO2Max"
                    } else {
                        algo = "HealthKit_VO2Max"
                    }

                    return [
                        "metric_type":        "VO2_MAX",
                        "value":              value,
                        "unit":               "ml/kg/min",
                        "start_time":         fmt.string(from: sample.startDate),
                        "end_time":           fmt.string(from: sample.endDate),
                        "source_name":        sample.sourceRevision.source.name,
                        "source_id":          sourceBundle,
                        "device_model":       sample.device?.model ?? "",
                        "source_algorithm":   algo,
                    ]
                }
                flutterResult(events)
            }
            store.execute(query)
        }
    }
}
