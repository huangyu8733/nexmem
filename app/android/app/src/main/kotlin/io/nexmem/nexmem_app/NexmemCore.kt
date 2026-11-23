package io.nexmem.nexmem_app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import mobile.EventSink
import mobile.Handle
import mobile.Mobile
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.spec.GCMParameterSpec

/**
 * gomobile 内核单例（P1-07）。
 *
 * 负责三件事：
 * 1. 从 Android Keystore 取出或生成主密钥，并在 `core.start` 前注入 Go 侧
 *    （主密钥本体只经信封加密落在 SharedPreferences，Keystore 条目删除后
 *    无法解密，对应“删除条目后无法解密”的验收语义）；
 * 2. 持有唯一的 [Handle]，把事件按 seq 写入 [EventRing] 供热重启重放；
 * 3. 向 Flutter 插件提供线程安全的 call / replay 入口。
 */
object NexmemCore : EventSink {

    private const val TAG = "NexmemCore"
    private const val KEK_ALIAS = "nexmem.master.kek"
    private const val PREFS = "nexmem_core"
    private const val PREF_WRAPPED_KEY = "wrapped_master_key"
    private const val PREF_START_CONFIG = "start_config"
    private const val GCM_IV_BYTES = 12
    private const val GCM_TAG_BITS = 128
    private const val MASTER_KEY_BYTES = 32

    private val main = Handler(Looper.getMainLooper())
    private val ring = EventRing()

    @Volatile
    private var handle: Handle? = null

    @Volatile
    private var listener: ((String) -> Unit)? = null

    /**
     * Dart 侧已消费的事件水位（P1-10）。
     *
     * 热重启只重建 Dart isolate、进程与内核仍在，因此水位留在原生侧即可；
     * 进程被杀后内核 seq 同样从头计数，水位随之归零，不会产生假缺口。
     */
    @Volatile
    var ackedSeq: Long = 0L
        private set

    /** 记录 Dart 已消费的最大事件序号（只增不减）。 */
    @Synchronized
    fun ack(seq: Long) {
        if (seq > ackedSeq) {
            ackedSeq = seq
        }
    }

    /** 注册事件监听（插件在引擎挂载时调用，回调已切回主线程）。 */
    fun attach(onEvent: (String) -> Unit) {
        listener = onEvent
    }

    fun detach() {
        listener = null
    }

    /** 幂等获取内核句柄；首次调用会注入主密钥。 */
    @Synchronized
    fun ensureHandle(context: Context): Handle {
        handle?.let { return it }
        val key = loadOrCreateMasterKey(context.applicationContext)
            ?: throw IllegalStateException("Android Keystore 主密钥不可用，无法启动内核")
        Mobile.setMasterKey(key)
        val created = Mobile.new_(this)
        handle = created
        return created
    }

    /** 处理一条请求信封；阻塞调用，必须运行在工作线程。 */
    fun call(context: Context, request: String): String {
        rememberStartConfig(context, request)
        return ensureHandle(context).call(request)
    }

    /**
     * 前台服务被系统回收后以 START_STICKY 重建时调用（P6-01）。
     *
     * 用最近一次 `core.start` 的 params 重新拉起内核，使锁屏期间被回收的
     * 进程恢复消息接收；Dart 侧稍后挂载时按 seq 重放本轮产生的事件。
     * 返回 false 表示用户从未启动过内核（没有可复用的配置），此时保持空服务。
     */
    @Synchronized
    fun ensureStarted(context: Context): Boolean {
        if (handle != null) {
            return true
        }
        val app = context.applicationContext
        val cfg = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PREF_START_CONFIG, null) ?: return false
        return try {
            val request = JSONObject()
                .put("id", "service-autostart")
                .put("method", "core.start")
                .put("params", JSONObject(cfg))
            ensureHandle(app).call(request.toString())
            true
        } catch (t: Throwable) {
            Log.e(TAG, "前台服务恢复内核失败: ${t.message}")
            false
        }
    }

    /** 记录最近一次 `core.start` 的 params，供服务重建时复用；其它请求忽略。 */
    private fun rememberStartConfig(context: Context, request: String) {
        // 热路径上的请求绝大多数不是 core.start，先用字符串过滤避免逐请求解析 JSON。
        if (!request.contains("core.start")) {
            return
        }
        try {
            val obj = JSONObject(request)
            if (obj.optString("method") != "core.start") {
                return
            }
            val params = obj.optJSONObject("params") ?: JSONObject()
            context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(PREF_START_CONFIG, params.toString())
                .apply()
        } catch (t: Throwable) {
            Log.w(TAG, "记录 core.start 配置失败: ${t.message}")
        }
    }

    /** 原生侧事件水位，供 Dart 持久化。 */
    fun lastSeq(): Long = handle?.lastSeq() ?: ring.lastSeq

    /** 热重启后按 seq 补齐事件；返回契约事件 JSON 数组。 */
    fun replaySince(since: Long): String {
        val replay = ring.replaySince(since)
        if (replay.complete) {
            return "[" + replay.frames.joinToString(",") + "]"
        }
        val resync = JSONObject()
            .put("seq", 0)
            .put("type", "resync_required")
            .put(
                "data",
                JSONObject()
                    .put("reason", "gap")
                    .put("since", since)
                    .put("oldest_seq", replay.oldestSeq)
                    .put("latest_seq", replay.latestSeq),
            )
        return "[$resync]"
    }

    /** 关闭内核；再次调用 [ensureHandle] 会重新创建。 */
    @Synchronized
    fun shutdown() {
        handle?.close()
        handle = null
        ring.reset()
        ackedSeq = 0L
    }

    override fun onEvent(payload: String) {
        val seq = try {
            JSONObject(payload).optLong("seq", 0L)
        } catch (t: Throwable) {
            Log.w(TAG, "事件载荷解析失败: ${t.message}")
            0L
        }
        ring.append(seq, payload)
        main.post { listener?.invoke(payload) }
    }

    /**
     * 读取或创建主密钥：Keystore 中的 AES-KEK 加密 32 字节随机主密钥。
     * 返回 null 表示条目缺失或损坏，调用方必须失败而不是静默重建。
     */
    private fun loadOrCreateMasterKey(context: Context): ByteArray? {
        return try {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val stored = prefs.getString(PREF_WRAPPED_KEY, null)

            val entry = keyStore.getEntry(KEK_ALIAS, null) as? KeyStore.SecretKeyEntry
            if (entry != null && stored != null) {
                return unwrap(entry.secretKey, Base64.decode(stored, Base64.NO_WRAP))
            }
            if (entry != null || stored != null) {
                // 只存在一半说明 Keystore 条目或密文被清除过，不能自动重建。
                Log.e(TAG, "主密钥信封不完整，拒绝重建")
                return null
            }

            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(
                    KEK_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .build(),
            )
            val kek = generator.generateKey()
            val master = ByteArray(MASTER_KEY_BYTES).also { java.security.SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.ENCRYPT_MODE, kek)
            val sealed = cipher.iv + cipher.doFinal(master)
            prefs.edit().putString(PREF_WRAPPED_KEY, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
            master
        } catch (t: Throwable) {
            Log.e(TAG, "主密钥加载失败: ${t.message}")
            null
        }
    }

    private fun unwrap(kek: javax.crypto.SecretKey, sealed: ByteArray): ByteArray {
        val iv = sealed.copyOfRange(0, GCM_IV_BYTES)
        val cipherText = sealed.copyOfRange(GCM_IV_BYTES, sealed.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, kek, GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(cipherText)
    }
}
