package io.nexmem.nexmem_app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var pendingPermissionResult: MethodChannel.Result? = null
    private var locationPlugin: LocationPlugin? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermission()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(NexmemPlugin())
        RemoteHostPlugin(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PERMISSIONS_CHANNEL)
            .setMethodCallHandler { call, result -> handlePermissionCall(call, result) }
        // 本机位置：用户主动点击「使用系统定位」时才调用，不申请开机自启等权限。
        locationPlugin = LocationPlugin(this).also { plugin ->
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LocationPlugin.CHANNEL)
                .setMethodCallHandler(plugin::onMethodCall)
        }
        // 推送事件的宿主实现尚未接入；这里注册一个空流，避免 Flutter 侧订阅
        // EventChannel 时触发 MissingPluginException 并被测试/运行时判为异常。
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, PUSH_EVENTS_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = Unit
                override fun onCancel(arguments: Any?) = Unit
            })
    }

    /**
     * Android 13+ 前台服务通知需要运行时授权（P6-01）。
     * 未授权时服务仍可运行，但通知不可见，系统更容易回收进程。
     */
    private fun requestNotificationPermission() {
        if (!hasNotificationPermission()) {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQUEST_NOTIFICATIONS,
            )
        }
    }

    private fun hasNotificationPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun permissionOf(kind: String?): String? = when (kind) {
        "camera" -> Manifest.permission.CAMERA
        "microphone" -> Manifest.permission.RECORD_AUDIO
        "notifications" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                Manifest.permission.POST_NOTIFICATIONS
            } else {
                null
            }
        else -> null
    }

    private fun statusOf(kind: String?): String {
        val permission = permissionOf(kind) ?: return "unsupported"
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            return "granted"
        }
        // Android 无法区分「从未申请」与「勾选不再询问」，统一返回 prompt；
        // 真正申请后的回调里再区分 denied / permanently_denied。
        return "prompt"
    }

    private fun handlePermissionCall(call: MethodCall, result: MethodChannel.Result) {
        val kind = call.argument<String>("kind")
        when (call.method) {
            "status" -> result.success(statusOf(kind))
            "request" -> {
                val permission = permissionOf(kind)
                if (permission == null) {
                    result.success("unsupported")
                    return
                }
                if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
                    result.success("granted")
                    return
                }
                // 同一时刻只处理一个申请，避免回调串台。
                pendingPermissionResult?.success("prompt")
                pendingPermissionResult = result
                requestPermissions(arrayOf(permission), REQUEST_PERMISSION)
            }
            "openSettings" -> {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.fromParts("package", packageName, null)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                result.success(runCatching { startActivity(intent) }.isSuccess)
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        locationPlugin?.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PERMISSION) {
            return
        }
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success("granted")
            return
        }
        val permanent = permissions.firstOrNull()?.let {
            !shouldShowRequestPermissionRationale(it)
        } ?: false
        result.success(if (permanent) "permanently_denied" else "denied")
    }

    companion object {
        private const val REQUEST_NOTIFICATIONS = 4101
        private const val REQUEST_PERMISSION = 4102
        private const val PERMISSIONS_CHANNEL = "nexmem/permissions"
        private const val PUSH_EVENTS_CHANNEL = "nexmem/push/events"
    }
}
