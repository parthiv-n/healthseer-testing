import Flutter
import HealthKit

/// Native HealthKit bridge for sleep apnea events.
///
/// The Flutter `health` package v13.x does not wrap the apnea category type
/// at all (the enum value does not exist in health.g.dart), so — like
/// VO2_MAX — the only way to live-sync it is a direct HealthKit query. The
/// backend already accepts SLEEP_APNEA_EVENT (registry, physiological range
/// 0–500/night, DAILY_SUM anomaly bucket); previously it could only arrive
/// via a manual Apple Health XML export.
///
/// The identifier is resolved at RUNTIME via the rawValue constructor so this
/// file compiles against any SDK: on devices/OS versions without the type,
/// categoryType(forIdentifier:) returns nil and every call returns [].
/// Apple has shipped the data under two names — "ApneaEvents" (the one the
/// backend XML importer maps) and "SleepApneaEvent" (watchOS 11 era) — so
/// both are probed.
///
/// Channel: com.tikcare.vitametric/sleepapnea
/// Methods: requestAuthorization() → Bool
///          readApneaEvents({startMs: Int, endMs: Int}) → [[String: Any]]
final class SleepApneaChannel: NSObject {
    private static let channelName = "com.tikcare.vitametric/sleepapnea"
    private static let store = HKHealthStore()

    private static var apneaType: HKCategoryType? {
        for raw in [
            "HKCategoryTypeIdentifierApneaEvents",
            "HKCategoryTypeIdentifierSleepApneaEvent",
        ] {
            if let t = HKObjectType.categoryType(
                forIdentifier: HKCategoryTypeIdentifier(rawValue: raw)
            ) {
                return t
            }
        }
        return nil
    }

    static func register(with messenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: channelName,
            binaryMessenger: messenger
        )
        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "requestAuthorization":
                requestAuthorization(flutterResult: result)
            case "readApneaEvents":
                guard
                    let args = call.arguments as? [String: Any],
                    let startMs = args["startMs"] as? Int,
                    let endMs = args["endMs"] as? Int
                else {
                    result(FlutterError(
                        code: "INVALID_ARGS",
                        message: "readApneaEvents requires startMs and endMs (Int milliseconds)",
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

    // MARK: - Private

    private static func requestAuthorization(flutterResult: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable(), let type = apneaType else {
            flutterResult(false)
            return
        }
        store.requestAuthorization(toShare: nil, read: [type]) { success, _ in
            flutterResult(success)
        }
    }

    private static func readSamples(
        start: Date,
        end: Date,
        flutterResult: @escaping FlutterResult
    ) {
        guard HKHealthStore.isHealthDataAvailable(), let type = apneaType else {
            flutterResult([])
            return
        }

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
            sampleType: type,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { _, samples, error in
            guard error == nil, let samples = samples as? [HKCategorySample] else {
                flutterResult([])
                return
            }

            let fmt = ISO8601DateFormatter()
            // One record per detected apnea episode, value 1.0 each — the
            // backend sums per night (DAILY_SUM_METRICS) into an AHI proxy.
            let events: [[String: Any]] = samples.map { sample in
                [
                    "metric_type":      "SLEEP_APNEA_EVENT",
                    "value":            1.0,
                    "unit":             "count",
                    "start_time":       fmt.string(from: sample.startDate),
                    "end_time":         fmt.string(from: sample.endDate),
                    "source_name":      sample.sourceRevision.source.name,
                    "source_id":        sample.sourceRevision.source.bundleIdentifier,
                    "device_model":     sample.device?.model ?? "",
                    "source_algorithm": "watchOS_breathing_disturbances",
                ]
            }
            flutterResult(events)
        }
        store.execute(query)
    }
}
