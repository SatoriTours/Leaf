package dev.leaf.testviews

import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Process
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import dev.leaf.runtime.*
import java.io.File

class MainActivity : LeafActivity() {
    override val leafLibrary = "leaf_android_views"
    private external fun marker(which: Int): Int
    private var ran = false
    private class TestView(context: android.content.Context, runtime: LeafRuntime) : LeafView(context, runtime) {
        var failNext = false
        override fun applyNative() {
            super.applyNative()
            if (failNext) { failNext = false; error("apply-1234") }
        }
    }
    companion object {
        private var firstOwner = 0L
        private var firstMount = 0L
        private var recreated = false
        private var expectedState = 2
    }
    override fun createLeafView(): LeafView = TestView(this, leafRuntime)
    private fun views(root: View): List<View> = listOf(root) +
        if(root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    private fun label(): TextView = views(leafView).filterIsInstance<TextView>().single { it.text.startsWith("计数 ") }
    private fun button(): Button = views(leafView).filterIsInstance<Button>().single()
    private fun result(value: String) {
        File(filesDir,"views-result.txt").appendText(value+"\n")
        Log.i("LeafViews",value)
    }
    override fun onLeafFailure(error: Throwable) {
        result("status=failed error=$error")
        super.onLeafFailure(error)
    }
    override fun onLeafAttached(view: LeafView) {
        check(!view.isInLayout) { "Attachment must run after Android layout returns" }
        if(ran) return
        ran=true
        view.post {
            try {
                val owner=leafRuntime.owner
                val mount=view.activityMount
                check(leafRuntime.resume(mount))
                leafRuntime.turn(mount)
                check(marker(0)==1 && marker(1)==1)
                if(!recreated) {
                    File(filesDir,"views-result.txt").writeText("")
                    check(marker(2)==0 && label().text.toString()=="计数 0 · 😀")
                    val beforeLabel=label(); val beforeButton=button()
                    check(beforeButton.performClick())
                    leafRuntime.turn(mount)
                    check(marker(2)==1 && label().text.toString()=="计数 1 · 😀")
                    check(label()===beforeLabel && button()===beforeButton)
                    leafRuntime.pause(mount)
                    beforeButton.performClick()
                    check(!leafRuntime.turn(mount) && marker(2)==1)
                    leafRuntime.resume(mount)
                    leafRuntime.turn(mount)
                    check(marker(2)==1)
                    var workerRejected=false
                    Thread {
                        try { leafRuntime.turn(mount) } catch(_:IllegalStateException) { workerRejected=true }
                    }.apply { start(); join() }
                    check(workerRejected)
                    (view as TestView).failNext=true
                    button().performClick()
                    var primary=false
                    try { leafRuntime.turn(mount) } catch(error:IllegalStateException) {
                        primary=error.message=="apply-1234"
                    }
                    check(primary && marker(2)==1 && label().text.toString()=="计数 1 · 😀")
                    // The removed pre-replay Button must not emit against the new
                    // binding just because its numeric entity handle is stable.
                    beforeButton.performClick()
                    leafRuntime.turn(mount)
                    check(marker(2)==1)
                    button().performClick(); leafRuntime.turn(mount)
                    check(marker(2)==2 && label().text.toString()=="计数 2 · 😀")
                    firstOwner=owner;firstMount=mount;recreated=true
                    result("phase=before_recreate pid=${Process.myPid()} owner=$owner mount=$mount state=2 stable_views=true paused=true worker=rejected primary=1234 replay=true stale_view=rejected")
                    recreate()
                } else {
                    check(owner==firstOwner && mount>firstMount)
                    check(marker(2)==expectedState && label().text.toString()=="计数 $expectedState · 😀")
                    check(!AndroidViewsBridge.phase(owner,firstMount,4))
                    result("status=passed pid=${Process.myPid()} owner=$owner mount=$mount retained=true factories=${marker(0)} initializations=${marker(1)} state=${marker(2)} activity_recreated=true orientation=${resources.configuration.orientation}")
                }
            } catch(error:Throwable) { onLeafFailure(error) }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if(intent.getBooleanExtra("inspect",false)) {
            check(marker(2)==3 && label().text.toString()=="计数 3 · 😀")
            expectedState=3
            result("touch=passed state=3 automatic_turn=true pid=${Process.myPid()}")
        }
        if(intent.getBooleanExtra("rotate",false)) requestedOrientation=ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        if(intent.getBooleanExtra("close",false)) finish()
    }
    override fun onDestroy() {
        val terminal=!isChangingConfigurations
        super.onDestroy()
        if(terminal) result("terminal=true disposals=${marker(3)}")
    }
}
