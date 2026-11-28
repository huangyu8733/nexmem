package io.nexmem.nexmem_app

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * 远程控制输入注入（Android）。
 *
 * Android 没有公开的全局键鼠合成接口，这里通过无障碍服务实现：
 * - 指针：`dispatchGesture` 点击/长按/拖拽/滑动滚动；
 * - 文本：写入系统剪贴板后对焦点输入框执行 `ACTION_PASTE`；
 * - 组合键：Ctrl/Cmd + A/C/X/V 映射为节点的全选/复制/剪切/粘贴；
 * - 返回键、Home 走全局动作；方向键等功能键暂不支持。
 *
 * 需要用户在「设置 → 无障碍 → Nexmem 远程控制」中手动启用。
 */
class RemoteControlAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: RemoteControlAccessibilityService? = null
            private set

        private const val SEGMENT_MS = 60L
        private const val TICK_MS = 40L
    }

    private val handler = Handler(Looper.getMainLooper())

    private var dragging = false
    private var continuing = false
    private var stroke: GestureDescription.StrokeDescription? = null

    private var lastX = 0f
    private var lastY = 0f
    private var dispatchedX = 0f
    private var dispatchedY = 0f

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    // ---------------------------------------------------------------------
    // 指针
    // ---------------------------------------------------------------------

    /** 由 MethodChannel 线程调用，统一切回主线程执行手势。 */
    fun handlePointer(
        type: String,
        x: Float,
        y: Float,
        buttons: Int,
        wheelY: Int,
        wheelX: Int = 0,
    ) {
        handler.post {
            when (type) {
                "move" -> {
                    if ((buttons and 1) != 0) {
                        if (dragging) drag(x, y) else beginDrag(x, y)
                    }
                }
                "button" -> when {
                    (buttons and 1) != 0 -> {
                        if (dragging) drag(x, y) else beginDrag(x, y)
                    }
                    (buttons and 2) != 0 -> {
                        if (dragging) endDrag()
                        longPress(x, y)
                    }
                    (buttons and 8) != 0 -> performGlobalAction(GLOBAL_ACTION_BACK)
                    (buttons and 16) != 0 -> performGlobalAction(GLOBAL_ACTION_RECENTS)
                    else -> if (dragging) endDrag()
                }
                "wheel" -> if (wheelY != 0) scroll(x, y, wheelY)
                else if (wheelX != 0) scrollHorizontal(x, y, wheelX)
                "pinch" -> if (wheelY != 0) scroll(x, y, wheelY)
            }
        }
    }

    /** 水平滚动：无障碍无原生横滑 API，用横向滑动手势近似。 */
    private fun scrollHorizontal(x: Float, y: Float, wheelX: Int) {
        endDrag()
        val direction = if (wheelX > 0) 1f else -1f
        val distance = (kotlin.math.abs(wheelX).coerceIn(1, 5) * 40f)
        val path = Path().apply {
            moveTo(x - direction * distance, y)
            lineTo(x + direction * distance, y)
        }
        dispatchGesture(gesture(path, 140L, false), null, null)
    }

    /**
     * 多点触摸：用两根手指的 Stroke 合成点击或捏合。Android 无障碍只能
     * 合成同起止时刻的笔画，因此把 down/move/up 各阶段分别下发：
     * - down：两指按下（用于建立锚点，实际以 up 阶段手势为准）；
     * - move：双指分别移动；
     * - up：两指聚拢（捏合缩小）/张开（捏合放大）或双指点击。
     */
    fun handleTouch(
        phase: String,
        points: List<Triple<Float, Float, Int>>,
    ) {
        handler.post {
            if (points.size < 2) {
                // 单指触摸退化为点击/拖拽。
                val p = points.firstOrNull() ?: return@post
                when (phase) {
                    "up" -> tap(p.first, p.second)
                    "move" -> if (dragging) drag(p.first, p.second) else beginDrag(p.first, p.second)
                }
                return@post
            }
            when (phase) {
                "up" -> {
                    if (dragging) endDrag()
                    twoFingerGesture(points[0].first, points[0].second, points[1].first, points[1].second)
                }
            }
        }
    }

    private fun twoFingerGesture(x1: Float, y1: Float, x2: Float, y2: Float) {
        val builder = GestureDescription.Builder()
        val duration = 180L
        val s1 = GestureDescription.StrokeDescription(
            Path().apply { moveTo(x1, y1) }, 0L, duration, false,
        )
        val s2 = GestureDescription.StrokeDescription(
            Path().apply { moveTo(x2, y2) }, 0L, duration, false,
        )
        dispatchGesture(
            builder.addStroke(s1).addStroke(s2).build(),
            null,
            null,
        )
    }

    private fun tap(x: Float, y: Float, duration: Long = 60L) {
        endDrag()
        val path = Path().apply { moveTo(x, y) }
        dispatchGesture(gesture(path, duration, false), null, null)
    }

    private fun longPress(x: Float, y: Float) {
        endDrag()
        val path = Path().apply { moveTo(x, y) }
        dispatchGesture(gesture(path, 700L, false), null, null)
    }

    private fun scroll(x: Float, y: Float, wheelY: Int) {
        if (wheelY == 0) {
            return
        }
        endDrag()
        val direction = if (wheelY > 0) 1f else -1f
        val distance = (kotlin.math.abs(wheelY).coerceIn(1, 5) * 40f)
        val path = Path().apply {
            moveTo(x, y - direction * distance)
            lineTo(x, y + direction * distance)
        }
        dispatchGesture(gesture(path, 140L + kotlin.math.abs(wheelY) * 20L, false), null, null)
    }

    private fun beginDrag(x: Float, y: Float) {
        endDrag()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            // API 26 以下不支持手势延续，退化为单击。
            tap(x, y, 80L)
            return
        }
        dragging = true
        continuing = false
        lastX = x
        lastY = y
        dispatchedX = x
        dispatchedY = y
        val path = Path().apply { moveTo(x, y) }
        val description = GestureDescription.StrokeDescription(path, 0L, SEGMENT_MS, true)
        if (!dispatchGesture(gesture(description), callback, null)) {
            resetDrag()
        }
    }

    private fun drag(x: Float, y: Float) {
        if (!dragging) {
            return
        }
        lastX = x
        lastY = y
        scheduleContinue()
    }

    private fun scheduleContinue() {
        if (!dragging || continuing) {
            return
        }
        val current = stroke ?: return
        continuing = true
        val targetX = lastX
        val targetY = lastY
        val path = Path().apply {
            moveTo(dispatchedX, dispatchedY)
            if (targetX == dispatchedX && targetY == dispatchedY) {
                // 零长度路径不合法，补一个极小位移保持按住状态。
                lineTo(targetX + 0.01f, targetY)
            } else {
                lineTo(targetX, targetY)
            }
        }
        try {
            val next = current.continueStroke(path, 0L, SEGMENT_MS, true)
            if (!dispatchGesture(gesture(next), callback, null)) {
                resetDrag()
                return
            }
            dispatchedX = targetX
            dispatchedY = targetY
        } catch (_: Exception) {
            // 手势已被系统结束（例如界面切换），放弃本次拖拽。
            resetDrag()
        }
    }

    private fun resetDrag() {
        stroke = null
        continuing = false
        dragging = false
    }

    private fun endDrag() {
        if (!dragging) {
            return
        }
        dragging = false
        val current = stroke
        if (current != null && !continuing) {
            val path = Path().apply {
                moveTo(dispatchedX, dispatchedY)
                lineTo(lastX + 0.01f, lastY)
            }
            dispatchGesture(
                gesture(current.continueStroke(path, 0L, 30L, false)),
                null,
                null,
            )
        }
        stroke = null
        dispatchedX = lastX
        dispatchedY = lastY
    }

    private val callback = object : GestureResultCallback() {
        override fun onCompleted(gestureDescription: GestureDescription?) {
            val completed = if (gestureDescription != null &&
                gestureDescription.strokeCount > 0
            ) {
                gestureDescription.getStroke(0)
            } else {
                null
            }
            continuing = false
            if (!dragging) {
                // 收尾时可能有在途笔画，补一段不延续的短笔画让手势结束。
                if (completed != null &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    completed.willContinue()
                ) {
                    val path = Path().apply {
                        moveTo(dispatchedX, dispatchedY)
                        lineTo(dispatchedX + 0.01f, dispatchedY)
                    }
                    dispatchGesture(
                        gesture(completed.continueStroke(path, 0L, 20L, false)),
                        null,
                        null,
                    )
                }
                stroke = null
                return
            }
            stroke = completed
            handler.postDelayed({ scheduleContinue() }, TICK_MS)
        }

        override fun onCancelled(gestureDescription: GestureDescription?) {
            stroke = null
            continuing = false
            dragging = false
        }
    }

    private fun gesture(
        description: GestureDescription.StrokeDescription,
    ): GestureDescription = GestureDescription.Builder().addStroke(description).build()

    private fun gesture(
        path: Path,
        duration: Long,
        willContinue: Boolean,
    ): GestureDescription = gesture(
        GestureDescription.StrokeDescription(path, 0L, duration, willContinue),
    )

    // ---------------------------------------------------------------------
    // 键盘与文本
    // ---------------------------------------------------------------------

    fun injectKey(key: String, modifiers: Int) {
        handler.post {
            val control = (modifiers and 2) != 0 || (modifiers and 8) != 0
            if (control) {
                when (key) {
                    "a" -> selectAll()
                    "c" -> nodeAction(AccessibilityNodeInfo.ACTION_COPY)
                    "x" -> nodeAction(AccessibilityNodeInfo.ACTION_CUT)
                    "v" -> nodeAction(AccessibilityNodeInfo.ACTION_PASTE)
                }
                return@post
            }
            when (key) {
                "enter" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                    node?.performAction(
                        AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER.id,
                    )
                }
                "escape" -> performGlobalAction(GLOBAL_ACTION_BACK)
                "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            }
        }
    }

    fun injectText(text: String) {
        if (text.isEmpty()) {
            return
        }
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("Nexmem", text))
        handler.post { nodeAction(AccessibilityNodeInfo.ACTION_PASTE) }
    }

    private fun nodeAction(action: Int): Boolean {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        return node.performAction(action)
    }

    private fun selectAll(): Boolean {
        val node = findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
        val length = node.text?.length ?: 0
        if (length == 0) {
            return false
        }
        val arguments = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, 0)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, length)
        }
        return node.performAction(
            AccessibilityNodeInfo.ACTION_SET_SELECTION,
            arguments,
        )
    }
}
