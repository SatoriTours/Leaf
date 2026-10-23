package dev.leaf.runtime

import android.app.Activity
import android.os.Bundle
import android.os.Build
import android.util.Log
import android.view.Choreographer
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.View
import android.widget.FrameLayout

/** Generic single-window host. The retained non-configuration holder owns only
 * a numeric Runtime ID. Every Activity gets fresh native Views and mount token.
 * A single main-Looper frame callback drains existing TaskService safe turns
 * while resumed; pause removes it, with no worker UI access or catch-up loop. */
abstract class LeafActivity : Activity() {
    protected abstract val leafLibrary: String
    protected lateinit var leafRuntime: LeafRuntime
        private set
    protected lateinit var leafView: LeafView
        private set
    private var resumed = false
    private var framePending = false
    private var stoppedByFailure = false
    private var layoutPosted = false
    private var contentWidth = 0
    private var contentHeight = 0
    private interface BackRegistration { fun dispose() }
    private var backRegistration:BackRegistration?=null
    private var backGesture:LeafView.BackRequest?=null
    private var backStarted=false
    private var backPending=false
    private fun beginSystemBack() {
        if(backStarted || backPending)return
        backStarted=true
        backGesture=if(resumed && !stoppedByFailure)leafView.beginBack() else null
    }
    private fun cancelSystemBack() {
        backGesture?.let {leafView.cancelBack(it)}
        backGesture=null;backStarted=false
    }
    private fun invokeSystemBack() {
        if(backPending)return
        if(!backStarted)beginSystemBack()
        val request=backGesture
        backGesture=null;backStarted=false
        if(request!=null)backPending=leafView.confirmBack(request)
    }
    private fun refreshSystemBack() {
        val eligible=resumed && !stoppedByFailure && leafView.activityMount!=0L && leafView.canNavigateBack()
        if(!eligible) {
            cancelSystemBack()
            backRegistration?.dispose();backRegistration=null
        } else if(backRegistration==null && Build.VERSION.SDK_INT>=33) {
            backRegistration=if(Build.VERSION.SDK_INT>=34)Back34.register(this) else Back33.register(this)
        }
    }
    private object Back33 {
        fun register(host:LeafActivity):BackRegistration {
            val callback=android.window.OnBackInvokedCallback {host.invokeSystemBack()}
            host.onBackInvokedDispatcher.registerOnBackInvokedCallback(0,callback)
            return object:BackRegistration {
                override fun dispose() {host.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)}
            }
        }
    }
    private object Back34 {
        fun register(host:LeafActivity):BackRegistration {
            val callback=object:android.window.OnBackAnimationCallback {
                override fun onBackStarted(event:android.window.BackEvent) {host.beginSystemBack()}
                override fun onBackProgressed(event:android.window.BackEvent) {} // No second history/animation commit.
                override fun onBackCancelled() {host.cancelSystemBack()}
                override fun onBackInvoked() {host.invokeSystemBack()}
            }
            host.onBackInvokedDispatcher.registerOnBackInvokedCallback(0,callback)
            return object:BackRegistration {
                override fun dispose() {host.onBackInvokedDispatcher.unregisterOnBackInvokedCallback(callback)}
            }
        }
    }
    @Deprecated("Legacy system back for API26–32")
    override fun onBackPressed() {
        if(Build.VERSION.SDK_INT<33 && resumed && leafView.canNavigateBack())invokeSystemBack()
        else super.onBackPressed()
    }
    private val frames get() = Choreographer.getInstance()
    private val frame = object : Choreographer.FrameCallback {
        override fun doFrame(time: Long) {
            framePending = false
            if (!resumed || stoppedByFailure || leafView.activityMount == 0L) return
            try {
                leafRuntime.turn(leafView.activityMount)
                backPending=false
                refreshSystemBack()
            }
            catch (error: Throwable) { onLeafFailure(error) }
            requestFrame()
        }
    }
    protected open fun createLeafView(): LeafView = LeafView(this, leafRuntime)
    protected open fun onLeafAttached(view: LeafView) {}
    protected open fun onLeafFailure(error: Throwable) { Log.e("LeafRuntime", "Native host stopped", error) }
    private fun requestFrame() {
        if (resumed && !stoppedByFailure && leafView.activityMount != 0L && !framePending) {
            framePending = true; frames.postFrameCallback(frame)
        }
    }
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        System.loadLibrary(leafLibrary)
        NativeBridge.initialize()
        leafRuntime = lastNonConfigurationInstance as? LeafRuntime ?: LeafRuntime.create(applicationContext)
        leafView = createLeafView()
        val content = FrameLayout(this)
        content.setOnApplyWindowInsetsListener { view, insets ->
            if (Build.VERSION.SDK_INT >= 30) {
                val bars = insets.getInsets(WindowInsets.Type.systemBars())
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            } else @Suppress("DEPRECATION") run {
                view.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                    insets.systemWindowInsetRight, insets.systemWindowInsetBottom)
            }
            insets
        }
        content.addView(leafView, FrameLayout.LayoutParams(-1, -1))
        setContentView(content)
        if (Build.VERSION.SDK_INT >= 30) window.insetsController?.setSystemBarsAppearance(
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS,
            WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS)
        else @Suppress("DEPRECATION") run {
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        }
        leafView.addOnLayoutChangeListener { _, _,_,_,_, _,_,_,_ ->
            // Never mount/measure/mutate the view tree from an Android layout
            // callback. One posted message observes the latest dimensions.
            if (!layoutPosted && !stoppedByFailure) {
                layoutPosted = true
                leafView.post {
                    layoutPosted = false
                    if (!isDestroyed && !isFinishing) attachForCurrentSize()
                }
            }
        }
    }
    private fun attachForCurrentSize() {
        val width = leafView.width; val height = leafView.height
        if (width <= 0 || height <= 0 || (width == contentWidth && height == contentHeight)) return
        try {
            val old = leafView.activityMount
            if (old != 0L) {
                cancelSystemBack()
                leafRuntime.pause(old)
                check(leafRuntime.detach(old))
                leafView.activityMount = 0
            }
            val scale = resources.displayMetrics.density.toDouble()
            val mount = leafRuntime.attach(leafView, width/scale, height/scale, scale)
            contentWidth = width; contentHeight = height
            if (resumed) leafRuntime.resume(mount)
            onLeafAttached(leafView)
            refreshSystemBack()
            requestFrame()
        } catch (error: Throwable) { stoppedByFailure = true; onLeafFailure(error) }
    }

    override fun onResume() {
        super.onResume(); resumed = true
        if (::leafView.isInitialized && leafView.activityMount != 0L) leafRuntime.resume(leafView.activityMount)
        if (::leafView.isInitialized) { refreshSystemBack(); requestFrame() }
    }
    override fun onPause() {
        if (::leafView.isInitialized)cancelSystemBack()
        resumed = false
        backRegistration?.dispose();backRegistration=null
        backPending=false
        frames.removeFrameCallback(frame); framePending = false
        if (::leafView.isInitialized && leafView.activityMount != 0L) leafRuntime.pause(leafView.activityMount)
        super.onPause()
    }
    @Deprecated("The retained holder contains no Activity or View")
    override fun onRetainNonConfigurationInstance(): Any? =
        if (::leafRuntime.isInitialized) leafRuntime else null
    override fun onDestroy() {
        backRegistration?.dispose();backRegistration=null
        try {
            val mount = if (::leafView.isInitialized) leafView.activityMount else 0L
            if (mount != 0L && leafRuntime.detach(mount)) leafView.activityMount = 0
        } catch (error: Throwable) { onLeafFailure(error) }
        if (::leafRuntime.isInitialized && !isChangingConfigurations) {
            try { leafRuntime.close() } catch (error: Throwable) { onLeafFailure(error) }
        }
        super.onDestroy()
    }
}
