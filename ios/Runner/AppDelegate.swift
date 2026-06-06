import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var talkbackPlugin: TalkbackAudioPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Register talkback here, not in didFinishLaunching: with the implicit
    // engine the root FlutterViewController isn't ready yet at launch, so the
    // old `window?.rootViewController as? FlutterViewController` cast returned
    // nil and the com.airfi.talkback/audio channel was never bound
    // (MissingPluginException on first invoke).
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TalkbackAudioPlugin")
    if let messenger = registrar?.messenger() {
      talkbackPlugin = TalkbackAudioPlugin(messenger: messenger)
    }
  }
}
