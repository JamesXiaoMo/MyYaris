import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Central manager for vehicle screen fullscreen and immersive display modes.
class SystemUiService {
  static const MethodChannel _channel = MethodChannel('com.myyaris.my_yaris/system_ui');

  /// Applies fullscreen immersive mode or restores standard system bars.
  ///
  /// When [fullscreen] is true:
  /// - Uses [SystemUiMode.immersiveSticky] to hide the status bar and system bars.
  /// - Allows transient swipe-in of system bars via gesture without disrupting layout.
  ///
  /// When [fullscreen] is false:
  /// - Restores normal system UI overlays ([SystemUiOverlay.top] and [SystemUiOverlay.bottom]).
  static Future<void> setFullscreen(bool fullscreen) async {
    try {
      if (fullscreen) {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.immersiveSticky,
        );
      } else {
        await SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: SystemUiOverlay.values,
        );
      }
    } catch (e) {
      debugPrint('[SystemUiService] Flutter SystemChrome error: $e');
    }

    try {
      await _channel.invokeMethod('setFullscreen', {'enabled': fullscreen});
    } catch (e) {
      // Native channel is an extra guarantee; silent if not implemented in headless test
      debugPrint('[SystemUiService] Native channel note: $e');
    }
  }
}
