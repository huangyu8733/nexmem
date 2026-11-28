package io.nexmem.nexmem_app

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Flutter 侧内核插件（P1-07）。
 *
 * 通道 `io.nexmem/core` 只做字节搬运：`call` 传请求信封、回响应信封，
 * 事件通过 `event` 反向调用推给 Dart。所有 `call` 都在单线程 executor 上
 * 串行执行，保证与桌面 FFI / Web 传输一致的“先请求后响应”时序。
 *
 * `pickFile` 是平台文件选择器（P2-08）：选中后把 `content://` 复制到应用
 * 缓存目录，回传 `name/size/mime/path`，内核按绝对路径直接读取。
 */
class NexmemPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.ActivityResultListener {

    companion object {
        const val CHANNEL = "io.nexmem/core"
        private const val REQUEST_PICK_FILE = 4201
        private const val REQUEST_PICK_DIRECTORY = 4202
        private const val REQUEST_PICK_IMAGE = 4203
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPick: MethodChannel.Result? = null
    private val worker = Executors.newSingleThreadExecutor { r ->
        Thread(r, "nexmem-core").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())
    private val detached = AtomicBoolean(false)

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val ch = MethodChannel(binding.binaryMessenger, CHANNEL)
        ch.setMethodCallHandler(this)
        channel = ch
        context = binding.applicationContext
        acquireMulticastLock(context!!)
        NexmemCore.attach { payload ->
            if (!detached.get()) {
                ch.invokeMethod("event", payload)
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detached.set(true)
        NexmemCore.detach()
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
        releaseMulticastLock()
    }

    /**
     * Android 默认过滤 Wi-Fi 组播包。mDNS 依赖 224.0.0.251:5353，
     * 必须持有 MulticastLock 才能收发局域网发现报文。
     */
    private fun acquireMulticastLock(ctx: Context) {
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return
        try {
            val lock = wifi.createMulticastLock("nexmem-mdns")
            lock.setReferenceCounted(true)
            lock.acquire()
            multicastLock = lock
        } catch (_: Throwable) {
            // 设备不支持或用户策略禁止时静默降级为其他发现源。
        }
    }

    private fun releaseMulticastLock() {
        try {
            multicastLock?.release()
        } catch (_: Throwable) {
        }
        multicastLock = null
    }

    /**
     * 返回当前 Wi-Fi 的局域网 IP（点分十进制）。
     *
     * Go runtime 在部分 MIUI 设备上因 SELinux 拒绝 netlink，net.Interfaces()
     * 会报 "route ip+net: netlinkrib: permission denied"，libp2p 无法把
     * /ip4/0.0.0.0 展开成局域网地址，mDNS 因此没有可广播地址。这里用系统
     * WifiManager 拿到 IP 注入内核，修复同一 WiFi 下的账号发现。
     */
    private fun localIpAddress(): String? {
        // 首选 Java NetworkInterface：不依赖定位权限，能拿到 wlan0 的单播 IP。
        try {
            val ifaces = java.net.NetworkInterface.getNetworkInterfaces()
            while (ifaces.hasMoreElements()) {
                val iface = ifaces.nextElement()
                if (!iface.isUp || iface.isVirtual || iface.isLoopback) continue
                val name = iface.name ?: ""
                // 优先 Wi-Fi 网卡，避免返回蜂窝网络 IP。
                if (!name.startsWith("wlan", ignoreCase = true)) continue
                val addrs = iface.inetAddresses
                while (addrs.hasMoreElements()) {
                    val addr = addrs.nextElement()
                    if (addr is java.net.Inet4Address && !addr.isLoopbackAddress &&
                        !addr.isLinkLocalAddress
                    ) {
                        return addr.hostAddress
                    }
                }
            }
        } catch (_: Throwable) {
        }
        // 兜底：WifiManager（Android 10+ 需定位权限）。
        val ctx = context ?: return null
        if (androidx.core.content.ContextCompat.checkSelfPermission(
                ctx, android.Manifest.permission.ACCESS_FINE_LOCATION
            ) != android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            return null
        }
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return null
        val ip = wifi.connectionInfo.ipAddress
        if (ip == 0) return null
        return String.format(
            java.util.Locale.US, "%d.%d.%d.%d",
            ip and 0xff, (ip shr 8) and 0xff, (ip shr 16) and 0xff, (ip shr 24) and 0xff
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "call" -> runAsync(result) { ctx ->
                NexmemCore.call(ctx, call.argument<String>("request") ?: "")
            }
            "replaySince" -> result.success(
                NexmemCore.replaySince(call.argument<Number>("since")?.toLong() ?: 0L),
            )
            "lastSeq" -> result.success(NexmemCore.lastSeq())
            "ackedSeq" -> result.success(NexmemCore.ackedSeq)
            "ack" -> {
                NexmemCore.ack(call.argument<Number>("seq")?.toLong() ?: 0L)
                result.success(null)
            }
            "dataDir" -> result.success(context?.filesDir?.absolutePath)
            "localIp" -> result.success(localIpAddress())
            "pickFile" -> pickFile(result)
            "pickImage" -> pickImage(result)
            "pickDirectory" -> pickDirectory(result)
            "openPath" -> openPath(call.argument<String>("path"), result)
            "openUrl" -> openUrl(call.argument<String>("url"), result)
            "startService" -> runAsync(result) { ctx ->
                NexmemService.start(ctx)
                ""
            }
            "stopService" -> runAsync(result) { ctx ->
                NexmemService.stop(ctx)
                ""
            }
            "shutdown" -> runAsync(result) { _ ->
                NexmemCore.shutdown()
                ""
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: (Context) -> String) {
        val ctx = context
        if (ctx == null) {
            result.error("CORE_UNAVAILABLE", "插件未挂载", null)
            return
        }
        worker.execute {
            try {
                val value = block(ctx)
                main.post { if (!detached.get()) result.success(value) }
            } catch (t: Throwable) {
                main.post {
                    if (!detached.get()) {
                        result.error("CORE_ERROR", t.message ?: t.javaClass.simpleName, null)
                    }
                }
            }
        }
    }

    /**
     * 打开系统文件选择器（P2-08）。用户取消返回 null；成功时先复制到缓存目录，
     * 避免 `content://` 授权随 Activity 生命周期失效。
     */
    /** 用系统应用打开本地路径（在线升级：APK 安装 / 打开下载目录）。 */
    private fun openPath(path: String?, result: MethodChannel.Result) {
        val ctx = context
        if (path.isNullOrBlank() || ctx == null) {
            result.error("INVALID_ARG", "路径为空或插件未挂载", null)
            return
        }
        try {
            val file = File(path)
            val uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(ctx, "${ctx.packageName}.fileprovider", file)
            } else {
                Uri.fromFile(file)
            }
            val mime = if (path.endsWith(".apk", ignoreCase = true)) {
                "application/vnd.android.package-archive"
            } else {
                "*/*"
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mime)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            result.success(null)
        } catch (t: Throwable) {
            result.error("OPEN_FAILED", t.message ?: t.javaClass.simpleName, null)
        }
    }

    /** 用系统浏览器打开发布页。 */
    private fun openUrl(url: String?, result: MethodChannel.Result) {
        val ctx = context
        if (url.isNullOrBlank() || ctx == null) {
            result.error("INVALID_ARG", "地址为空或插件未挂载", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            ctx.startActivity(intent)
            result.success(null)
        } catch (t: Throwable) {
            result.error("OPEN_FAILED", t.message ?: t.javaClass.simpleName, null)
        }
    }

    /** 选择整个目录树（P2P 文件夹共享）：SAF 授权后复制到应用缓存供内核读取。 */
    private fun pickDirectory(result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "当前没有可用的界面", null)
            return
        }
        if (pendingPick != null) {
            result.error("PICK_BUSY", "已有一个文件选择正在进行", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        try {
            pendingPick = result
            pendingDirPick = true
            act.startActivityForResult(intent, REQUEST_PICK_DIRECTORY)
        } catch (t: Throwable) {
            pendingPick = null
            pendingDirPick = false
            result.error("PICK_FAILED", t.message ?: "无法打开目录选择器", null)
        }
    }

    private var pendingDirPick = false

    private fun pickFile(result: MethodChannel.Result) {
        pendingDirPick = false
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "当前没有可用的界面", null)
            return
        }
        if (pendingPick != null) {
            result.error("PICK_BUSY", "已有一个文件选择正在进行", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        pendingPick = result
        try {
            act.startActivityForResult(intent, REQUEST_PICK_FILE)
        } catch (t: Throwable) {
            pendingPick = null
            result.error("PICK_FAILED", t.message ?: "无法打开文件选择器", null)
        }
    }

    /** 打开系统相册选图片（ACTION_PICK 只列媒体库，不走文件管理器）。 */
    private fun pickImage(result: MethodChannel.Result) {
        pendingDirPick = false
        val act = activity
        if (act == null) {
            result.error("NO_ACTIVITY", "当前没有可用的界面", null)
            return
        }
        if (pendingPick != null) {
            result.error("PICK_BUSY", "已有一个文件选择正在进行", null)
            return
        }
        val intent = Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
            type = "image/*"
        }
        pendingPick = result
        try {
            act.startActivityForResult(intent, REQUEST_PICK_IMAGE)
        } catch (t: Throwable) {
            pendingPick = null
            result.error("PICK_FAILED", t.message ?: "无法打开系统相册", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FILE &&
            requestCode != REQUEST_PICK_DIRECTORY &&
            requestCode != REQUEST_PICK_IMAGE
        ) {
            return false
        }
        val result = pendingPick ?: return true
        pendingPick = null
        val isDir = requestCode == REQUEST_PICK_DIRECTORY
        pendingDirPick = false
        val uri: Uri? = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return true
        }
        val ctx = context
        if (ctx == null) {
            result.error("CORE_UNAVAILABLE", "插件未挂载", null)
            return true
        }
        worker.execute {
            try {
                if (isDir) {
                    val path = copyPickedDirectory(ctx, uri)
                    main.post { if (!detached.get()) result.success(path) }
                } else {
                    val picked = copyPickedFile(ctx, uri)
                    main.post { if (!detached.get()) result.success(picked) }
                }
            } catch (t: Throwable) {
                main.post {
                    if (!detached.get()) {
                        result.error("PICK_FAILED", t.message ?: t.javaClass.simpleName, null)
                    }
                }
            }
        }
        return true
    }

    /** 把 SAF 目录树递归复制到 `cacheDir/nexmem-shared`，返回根目录绝对路径。 */
    private fun copyPickedDirectory(ctx: Context, uri: Uri): String {
        val tree = DocumentFile.fromTreeUri(ctx, uri)
            ?: throw IllegalStateException("无法读取所选目录")
        val rootName = (tree.name ?: "shared").replace(Regex("[^A-Za-z0-9._-]"), "_")
            .ifEmpty { "shared" }
        val base = File(ctx.cacheDir, "nexmem-shared")
        val root = File(base, "${System.currentTimeMillis()}-$rootName").apply { mkdirs() }
        copyTree(ctx, tree, root)
        return root.absolutePath
    }

    private fun copyTree(ctx: Context, source: DocumentFile, target: File) {
        for (child in source.listFiles()) {
            val name = child.name ?: continue
            val safe = name.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "item" }
            if (child.isDirectory) {
                val sub = File(target, safe).apply { mkdirs() }
                copyTree(ctx, child, sub)
            } else if (child.isFile) {
                val file = File(target, safe)
                val input = ctx.contentResolver.openInputStream(child.uri)
                    ?: continue
                input.use { src -> file.outputStream().use { dst -> src.copyTo(dst) } }
            }
        }
    }

    /** 把选择结果复制到 `cacheDir/nexmem-picked` 并返回 Dart 侧字段。 */
    private fun copyPickedFile(ctx: Context, uri: Uri): Map<String, Any> {
        val resolver = ctx.contentResolver
        val displayName = queryDisplayName(resolver, uri) ?: uri.lastPathSegment ?: "file"
        val mime = resolver.getType(uri) ?: ""
        val dir = File(ctx.cacheDir, "nexmem-picked").apply { mkdirs() }
        val safe = displayName.replace(Regex("[^A-Za-z0-9._-]"), "_").ifEmpty { "file" }
        val target = File(dir, "${System.currentTimeMillis()}-$safe")
        val input = resolver.openInputStream(uri) ?: throw IllegalStateException("无法读取所选文件")
        input.use { source ->
            target.outputStream().use { sink -> source.copyTo(sink) }
        }
        return mapOf(
            "name" to displayName,
            "size" to target.length(),
            "mime" to mime,
            "path" to target.absolutePath,
        )
    }

    private fun queryDisplayName(resolver: ContentResolver, uri: Uri): String? {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index)
                }
            }
        }
        return null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        detachActivity()
    }

    private fun detachActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        pendingPick?.success(null)
        pendingPick = null
    }
}
