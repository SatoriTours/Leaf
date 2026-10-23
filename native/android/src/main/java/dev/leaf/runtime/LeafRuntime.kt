package dev.leaf.runtime

import android.os.Looper

/** Retain this owner across Activity recreation. It holds a numeric owner ID
 * only, never an Activity, View, Context or JNI environment. */
class LeafRuntime private constructor(val owner: Long) {
    private var closed = false
    private var backRequest = 0L
    internal fun nextBackRequest():Long {
        mainThread(); check(!closed && backRequest!=Long.MAX_VALUE)
        return ++backRequest
    }
    companion object {
        private val pendingCleanup = linkedMapOf<Long, LeafRuntime>()
        private fun mainThread() { check(Looper.myLooper() === Looper.getMainLooper()) }
        fun create(): LeafRuntime = createOwner(null)
        fun create(context: android.content.Context): LeafRuntime = createOwner(context.applicationContext)
        private fun createOwner(context: android.content.Context?): LeafRuntime {
            mainThread()
            val result = if (context == null) AndroidViewsBridge.createOwner()
                else AndroidViewsBridge.createOwnerWithResources(context.assets,
                    NativeBridge.encodeUtf8(context.filesDir.absolutePath),
                    NativeBridge.encodeUtf8(context.cacheDir.absolutePath))
            val runtime = LeafRuntime(result.owner)
            if (result.status != 0 || result.failure != null) {
                if (result.owner != 0L) pendingCleanup[result.owner] = runtime
                result.requireSuccess()
            }
            return runtime
        }
        /** Explicit retry after a failed startup/terminal cleanup. No timer or
         * hidden replacement Runtime is created to bypass a retained owner. */
        fun retryPendingCleanup() {
            mainThread()
            pendingCleanup.values.toList().forEach { it.close() }
        }
    }
    fun attach(view: LeafView, width: Double, height: Double, scale: Double): Long {
        mainThread(); check(!closed && view.activityMount == 0L)
        val result = AndroidViewsBridge.attach(owner, view, width, height, scale)
        view.activityMount = result.mount // Capture cleanup token before throwing.
        result.requireSuccess()
        return result.mount
    }
    fun resume(mount: Long): Boolean = AndroidViewsBridge.phase(owner, mount, 1)
    fun pause(mount: Long): Boolean = AndroidViewsBridge.phase(owner, mount, 2)
    fun turn(mount: Long): Boolean = AndroidViewsBridge.phase(owner, mount, 3)
    fun detach(mount: Long): Boolean = AndroidViewsBridge.phase(owner, mount, 4)
    fun close() {
        mainThread()
        if (closed) return
        pendingCleanup[owner] = this
        AndroidViewsBridge.close(owner) // Failure leaves this cleanup owner rooted.
        closed = true
        pendingCleanup.remove(owner)
    }
}
