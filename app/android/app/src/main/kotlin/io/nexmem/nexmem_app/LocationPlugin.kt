package io.nexmem.nexmem_app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * 系统定位通道：只在用户主动点击「使用系统定位」时由 Dart 侧调用。
 * 仅依赖系统 LocationManager，不引入 play-services / geolocator pod。
 */
class LocationPlugin(private val activity: Activity) {

    companion object {
        const val CHANNEL = "nexmem/location"
        private const val REQUEST_LOCATION = 4103
        private const val TIMEOUT_MS = 20_000L
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var permissionAskedBefore = false

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isServiceEnabled" -> result.success(isServiceEnabled())
            "checkPermission" -> result.success(checkPermission())
            "requestPermission" -> requestPermission(result)
            "getCurrentPosition" -> getCurrentPosition(result)
            else -> result.notImplemented()
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != REQUEST_LOCATION) return
        val result = pendingPermissionResult ?: return
        pendingPermissionResult = null
        permissionAskedBefore = true
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (granted) {
            result.success("granted")
            return
        }
        val permanent = permissions.firstOrNull()?.let {
            !activity.shouldShowRequestPermissionRationale(it)
        } ?: false
        result.success(if (permanent) "deniedForever" else "denied")
    }

    private fun manager(): LocationManager? =
        activity.getSystemService(Context.LOCATION_SERVICE) as? LocationManager

    private fun isServiceEnabled(): Boolean {
        val manager = manager() ?: return false
        return try {
            manager.isProviderEnabled(LocationManager.GPS_PROVIDER) ||
                manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
        } catch (_: Exception) {
            false
        }
    }

    private fun permissionGranted(): Boolean =
        activity.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            activity.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun checkPermission(): String {
        if (!permissionGranted()) {
            val permanent = permissionAskedBefore &&
                !activity.shouldShowRequestPermissionRationale(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                )
            return if (permanent) "deniedForever" else "denied"
        }
        return "granted"
    }

    private fun requestPermission(result: MethodChannel.Result) {
        if (permissionGranted()) {
            result.success("granted")
            return
        }
        // 同一时刻只处理一个申请，避免权限回调串台。
        pendingPermissionResult?.success("denied")
        pendingPermissionResult = result
        permissionAskedBefore = true
        activity.requestPermissions(
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.ACCESS_COARSE_LOCATION,
            ),
            REQUEST_LOCATION,
        )
    }

    private fun getCurrentPosition(result: MethodChannel.Result) {
        if (!permissionGranted()) {
            result.error("PERMISSION_DENIED", "定位权限尚未授予", null)
            return
        }
        val manager = manager()
        if (manager == null) {
            result.error("UNSUPPORTED", "系统定位不可用", null)
            return
        }
        val providers = enabledProviders(manager)
        if (providers.isEmpty()) {
            result.error("SERVICE_DISABLED", "定位服务未开启", null)
            return
        }

        val delivered = AtomicBoolean(false)
        var timeoutRunnable: Runnable? = null
        var listener: LocationListener? = null
        val finish: (Location?) -> Unit = { location ->
            if (delivered.compareAndSet(false, true)) {
                timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
                listener?.let { active -> runCatching { manager.removeUpdates(active) } }
                if (location != null) {
                    result.success(positionMap(location))
                } else {
                    result.error("TIMEOUT", "获取定位超时", null)
                }
            }
        }

        listener = object : LocationListener {
            override fun onLocationChanged(location: Location) = finish(location)

            @Deprecated("Deprecated in Java")
            override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

            override fun onProviderEnabled(provider: String) = Unit
            override fun onProviderDisabled(provider: String) = Unit
        }
        timeoutRunnable = Runnable { finish(lastKnown(manager, providers)) }
        mainHandler.postDelayed(timeoutRunnable, TIMEOUT_MS)

        var requested = false
        for (provider in providers) {
            try {
                manager.requestSingleUpdate(provider, listener, Looper.getMainLooper())
                requested = true
                break
            } catch (_: SecurityException) {
                // 下一provider 重试
            } catch (_: IllegalArgumentException) {
                // 该 provider 不支持单次更新
            }
        }
        if (!requested) {
            finish(lastKnown(manager, providers))
        }
    }

    private fun enabledProviders(manager: LocationManager): List<String> {
        val providers = mutableListOf<String>()
        for (provider in listOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
        )) {
            try {
                if (manager.isProviderEnabled(provider)) providers.add(provider)
            } catch (_: Exception) {
                // 忽略不可用 provider
            }
        }
        return providers
    }

    private fun lastKnown(manager: LocationManager, providers: List<String>): Location? {
        for (provider in providers) {
            try {
                val location = manager.getLastKnownLocation(provider)
                if (location != null) return location
            } catch (_: SecurityException) {
                // 忽略
            }
        }
        return null
    }

    private fun positionMap(location: Location): Map<String, Double> = mapOf(
        "latitude" to location.latitude,
        "longitude" to location.longitude,
        "accuracy" to location.accuracy.toDouble(),
    )
}
