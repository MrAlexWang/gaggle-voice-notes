import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android 原生能力封装（前台服务 / 通知权限 / 电池白名单）
///
/// 对应原生实现：`android/app/src/main/kotlin/com/gaggle/gaggle/MainActivity.kt`
/// 与 `RecordingService.kt`。非 Android 平台全部是空操作，桌面端调用无副作用。
class AndroidForeground {
  AndroidForeground._();

  static const MethodChannel _ch = MethodChannel('gaggle/native');

  /// 从通知点「停止」时回调（应用会被拉到前台）
  static void Function()? onStopFromNotification;

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// 录音开始时调用：起前台服务 + 常驻通知，避免息屏后被系统回收
  static Future<void> start() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('startRecordingService');
    } catch (_) {
      // 服务起不来不影响录音本身，只是少了一层保活
    }
  }

  /// 录音结束 / 放弃时调用
  static Future<void> stop() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('stopRecordingService');
    } catch (_) {}
  }

  /// Android 13+ 需要运行时授权通知，否则前台服务的通知不显示
  static Future<bool> requestNotificationPermission() async {
    if (!supported) return true;
    try {
      final v = await _ch.invokeMethod<bool>('requestNotificationPermission');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 是否已加入「不受电池优化限制」白名单
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!supported) return true;
    try {
      final v = await _ch.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 弹系统授权框（部分国产 ROM 不支持，会自动退到应用详情页）
  static Future<void> requestIgnoreBatteryOptimizations() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  /// 打开系统的「应用信息」页，用于厂商自启动/后台管理
  static Future<void> openAppSettings() async {
    if (!supported) return;
    try {
      await _ch.invokeMethod('openAppSettings');
    } catch (_) {}
  }

  /// 注册原生回调（App 启动时调用一次）
  static void listen() {
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'stopRecordingFromNotification') {
        onStopFromNotification?.call();
      }
      return null;
    });
  }
}
