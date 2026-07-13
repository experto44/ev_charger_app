import Flutter
import UIKit
import FirebaseMessaging

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Forward the APNs device token to Firebase Messaging explicitly.
  //
  // The CI builds on a newer Flutter "stable" that auto-migrates the app to the
  // UIScene lifecycle at build time (see build log: "Finished migration to
  // UIScene lifecycle"). Under that lifecycle FirebaseMessaging's automatic
  // swizzling of this callback can fail to fire, so the APNs token never
  // reaches FCM and getToken() throws `apns-token-not-set` even though push is
  // fully provisioned. Setting `Messaging.messaging().apnsToken` here does the
  // hand-off directly and is safe/idempotent alongside the swizzling. This is
  // why iOS "Notify me!" alerts failed while Android worked.
  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    Messaging.messaging().apnsToken = deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }
}
