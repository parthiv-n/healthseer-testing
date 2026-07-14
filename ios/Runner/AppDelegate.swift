import Flutter
import UIKit
import workmanager_apple

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Register the Dart callback dispatcher so WorkManager can run tasks in
    // a headless Dart isolate when the app is in the background.
    //
    // The custom MethodChannels must ALSO be registered here: the headless
    // engine has its own binary messenger, and GeneratedPluginRegistrant only
    // registers FlutterPlugin classes — Vo2MaxChannel / DeviceLockChannel are
    // plain channels, so without these lines any invokeMethod on them from
    // the background isolate throws MissingPluginException and fails the
    // entire background sync.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
      if let registrar = registry.registrar(forPlugin: "com.tikcare.vitametric.NativeChannels") {
        Vo2MaxChannel.register(with: registrar.messenger())
        DeviceLockChannel.register(with: registrar.messenger())
        SleepApneaChannel.register(with: registrar.messenger())
      }
    }

    // Bind the BGTaskScheduler launch handler for the identifier declared in
    // Info.plist (BGTaskSchedulerPermittedIdentifiers). The Dart-side
    // Workmanager().registerPeriodicTask(...) only SUBMITS a BGAppRefreshTask
    // request — iOS refuses to launch a task whose identifier has no handler
    // registered before didFinishLaunching returns, so without this call the
    // background sync never ran at all.
    WorkmanagerPlugin.registerPeriodicTask(
      withIdentifier: "vitametric.periodicSync",
      frequency: NSNumber(value: 6 * 60 * 60)
    )

    // HealthKit background delivery: observer queries expedite the BGTask
    // above when new data lands in HealthKit (watch transfers, overnight
    // sleep staging, third-party backfills). Must run AFTER the handler
    // registration so the expedited submits have a bound launch handler.
    HealthKitObserverBootstrap.start()

    // Register native HealthKit bridges for types not exposed by the `health`
    // plugin, on the foreground engine's messenger.
    if let messenger = (window?.rootViewController as? FlutterViewController)?.binaryMessenger {
      Vo2MaxChannel.register(with: messenger)
      DeviceLockChannel.register(with: messenger)
      SleepApneaChannel.register(with: messenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
