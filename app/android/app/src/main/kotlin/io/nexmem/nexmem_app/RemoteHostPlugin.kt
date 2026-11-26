package io.nexmem.nexmem_app

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.hardware.display.DisplayManager
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.Display
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 移动端被控的原生通道。
 *
 * 负责：
 * - 开始/停止 mediaProjection 前台服务；
 * - 查询并打开无障碍服务设置；
 * - 把归一化坐标换算成屏幕像素后交给无障碍服务注入。
 */
class RemoteHostPlugin(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL).apply {
        setMethodCallHandler(this@RemoteHostPlugin)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startScreenCapture" -> {
                RemoteHostService.start(activity)
                result.success(true)
            }
            "stopScreenCapture" -> {
                RemoteHostService.stop(activity)
                result.success(true)
            }
            "accessibilityEnabled" -> {
                result.success(RemoteControlAccessibilityService.instance != null)
            }
            "openAccessibilitySettings" -> {
                try {
                    activity.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                } catch (_: Exception) {
                    // 部分定制系统缺少该设置页。
                }
                result.success(true)
            }
            "injectPointer" -> {
                val service = RemoteControlAccessibilityService.instance
                if (service == null) {
                    result.success(false)
                    return
                }
                val type = call.argument<String>("type") ?: "move"
                val xNorm = (call.argument<Int>("x") ?: 0).coerceIn(0, 65535)
                val yNorm = (call.argument<Int>("y") ?: 0).coerceIn(0, 65535)
                val buttons = call.argument<Int>("buttons") ?: 0
                val wheelY = call.argument<Int>("wheelY") ?: 0
                val (width, height) = screenSize()
                service.handlePointer(
                    type,
                    xNorm / 65535f * width,
                    yNorm / 65535f * height,
                    buttons,
                    wheelY,
                )
                result.success(true)
            }
            "injectKey" -> {
                val service = RemoteControlAccessibilityService.instance
                if (service == null) {
                    result.success(false)
                    return
                }
                service.injectKey(
                    call.argument<String>("key") ?: "",
                    call.argument<Int>("modifiers") ?: 0,
                )
                result.success(true)
            }
            "injectText" -> {
                val service = RemoteControlAccessibilityService.instance
                if (service == null) {
                    result.success(false)
                    return
                }
                service.injectText(call.argument<String>("text") ?: "")
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    @Suppress("DEPRECATION")
    private fun screenSize(): Pair<Float, Float> {
        val manager =
            activity.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
        val display: Display = manager.getDisplay(Display.DEFAULT_DISPLAY)
            ?: return 1080f to 1920f
        val metrics = DisplayMetrics()
        display.getRealMetrics(metrics)
        return metrics.widthPixels.toFloat() to metrics.heightPixels.toFloat()
    }

    companion object {
        private const val CHANNEL = "io.nexmem/remote_host"
    }
}
