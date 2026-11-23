package io.nexmem.nexmem_app

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
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
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
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
            "pickFile" -> pickFile(result)
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
    private fun pickFile(result: MethodChannel.Result) {
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

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FILE) {
            return false
        }
        val result = pendingPick ?: return true
        pendingPick = null
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
                val picked = copyPickedFile(ctx, uri)
                main.post { if (!detached.get()) result.success(picked) }
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
