// iOS 应用代理。
//
// 注册 Flutter 插件后交回 FlutterAppDelegate 的默认生命周期;
// 业务逻辑全部在 Dart 层,这里不承载额外原生代码。
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
