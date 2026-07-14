import HealthKit
import BackgroundTasks

/// Wires up HealthKit background delivery.
///
/// The app has carried the `com.apple.developer.healthkit.background-delivery`
/// entitlement since day one but never used it — sync was purely poll-based
/// (a 6-hourly BGAppRefreshTask), so data that landed in HealthKit between
/// polls (watch transfer batches, overnight sleep staging, third-party
/// backfills) waited for the next opportunistic wake, or for the user to
/// open the app.
///
/// This bootstrap registers an HKObserverQuery per high-value type and
/// enables background delivery for it. When HealthKit reports new data, the
/// handler submits an expedited BGAppRefreshTaskRequest for the SAME
/// identifier the WorkManager periodic task uses ("vitametric.periodicSync"),
/// so the existing Dart sync pipeline runs — no second code path. iOS holds
/// observer notifications while the device is locked and delivers them when
/// the store becomes readable, which is exactly the coverage the blind
/// 6-hour poll lacked.
///
/// Must be called from AppDelegate AFTER WorkmanagerPlugin.registerPeriodicTask
/// has bound the launch handler for the identifier.
final class HealthKitObserverBootstrap {
    private static let store = HKHealthStore()
    private static let taskIdentifier = "vitametric.periodicSync"

    /// Types worth waking the app for. Low-churn, high-value: these are the
    /// metrics a 2-hour anchor window historically leapfrogged. HEART_RATE is
    /// deliberately absent — it updates every few minutes and would burn the
    /// BGTask budget for no coverage gain (HR rides along on every sync).
    private static let observedQuantityIdentifiers: [HKQuantityTypeIdentifier] = [
        .restingHeartRate,
        .oxygenSaturation,
        .respiratoryRate,
        .vo2Max,
        .stepCount,
        .appleExerciseTime,
    ]

    static func start() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        var sampleTypes: [HKSampleType] = observedQuantityIdentifiers.compactMap {
            HKQuantityType.quantityType(forIdentifier: $0)
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            sampleTypes.append(sleep)
        }

        for type in sampleTypes {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completionHandler, error in
                if error == nil {
                    scheduleExpeditedSync()
                }
                // Always complete — otherwise HealthKit throttles future
                // deliveries for this observer.
                completionHandler()
            }
            store.execute(query)
            // .hourly caps delivery rate; observer wakes are a scheduling
            // hint, not the sync itself, so coarse granularity is fine.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Submit an expedited request for the existing periodic-sync BGTask.
    /// Replaces any pending request with an earlier begin date; failures are
    /// ignored (the 6-hourly WorkManager schedule remains the fallback).
    private static func scheduleExpeditedSync() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
