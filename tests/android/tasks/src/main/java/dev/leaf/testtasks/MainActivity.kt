package dev.leaf.testtasks

import android.content.Intent
import android.os.Process
import android.os.SystemClock
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import dev.leaf.runtime.*
import java.io.File

/** Real HOME/onPause and foreground/recreate are driven by adb. Polling below
 * is bounded test observation on the UI Looper, never a production scheduler. */
class MainActivity : LeafActivity() {
    override val leafLibrary = "leaf_android_tasks"
    private external fun marker(which: Int): Int
    private var ran = false
    private val testHandler = Handler(Looper.getMainLooper())
    companion object {
        private var firstOwner = 0L
        private var firstMount = 0L
        private var background = false
        private var recreated = false
        private var oldLabel: TextView? = null // Deliberate fixture pin, not leak evidence.
    }
    private fun views(root: View): List<View> = listOf(root) +
        if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
    private fun label(): TextView = views(leafView).filterIsInstance<TextView>().single {
        it !is Button && it.text.toString() != "Leaf · 后台任务"
    }
    private fun button(): Button = views(leafView).filterIsInstance<Button>().single()
    private fun result(message: String) {
        File(filesDir,"tasks-result.txt").appendText(message+"\n")
        Log.i("LeafTasks",message)
    }
    override fun onLeafFailure(error: Throwable) {
        result("status=failed error=$error")
        super.onLeafFailure(error)
    }
    private fun await(condition: () -> Boolean, ready: () -> Unit) {
        val deadline = SystemClock.uptimeMillis()+5000
        val observer = object : Runnable {
            override fun run() {
                try {
                    if (condition()) ready()
                    else {
                        check(SystemClock.uptimeMillis() < deadline) { "Task fixture deadline" }
                        testHandler.postDelayed(this,16)
                    }
                } catch (error: Throwable) { onLeafFailure(error) }
            }
        }
        testHandler.post(observer)
    }
    override fun onLeafAttached(view: LeafView) {
        if (ran) return
        ran = true
        view.post {
            try {
                val mount = view.activityMount
                if (!recreated) {
                    File(filesDir,"tasks-result.txt").writeText("")
                    firstOwner = leafRuntime.owner; firstMount = mount; oldLabel = label()
                    check(label().text.toString() == "pending")
                    check(button().performClick())
                    leafRuntime.turn(mount)
                    await({marker(4)==1}) {
                        check(marker(7)==1 && marker(2)==0)
                        result("phase=worker_started pid=${Process.myPid()} owner=$firstOwner mount=$mount separate_thread=true callbacks=0")
                    }
                } else {
                    check(leafRuntime.owner==firstOwner && mount>firstMount)
                    await({marker(2)==1}) {
                        check(marker(0)==1 && marker(1)==1 && marker(6)==1 && marker(8)==1)
                        check(label().text.toString()=="后台 中文😀" && oldLabel?.text.toString()=="pending")
                        check(!AndroidViewsBridge.phase(firstOwner,firstMount,3))
                        result("phase=delivered pid=${Process.myPid()} owner=$firstOwner mount=$mount retained=true callbacks=1 factories=1 initializations=1 ui_thread=true old_view=pending result=后台_中文😀")
                        oldLabel=null
                        check(button().performClick())
                        await({marker(9)==1}) {
                            check(marker(2)==1)
                            result("phase=cancel_wait pid=${Process.myPid()} calls=2 callbacks=1")
                        }
                    }
                }
            } catch (error: Throwable) { onLeafFailure(error) }
        }
    }
    override fun onPause() {
        super.onPause() // Native delivery is paused before releasing worker.
        if (!background && !recreated && !isFinishing) {
            background = true
            marker(10)
            await({marker(5)==1}) {
                check(marker(2)==0 && marker(6)==0 && label().text.toString()=="pending")
                check(!leafRuntime.turn(leafView.activityMount))
                result("phase=background pid=${Process.myPid()} worker_reached_return=true callbacks=0 accepted=pending native=pending safe_turn=false")
            }
        }
    }
    override fun onResume() {
        super.onResume()
        if (background && !recreated) {
            // Suppress the frame queued by super before requesting recreation;
            // only the new Activity is allowed to deliver the retained result.
            leafRuntime.pause(leafView.activityMount)
            recreated=true
            recreate()
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if(intent.getBooleanExtra("close",false)) finish()
    }
    override fun onDestroy() {
        val terminal=!isChangingConfigurations
        super.onDestroy()
        if (terminal) await({marker(11)==1}) {
            check(marker(3)==1 && marker(2)==1 && marker(12)==0)
            result("status=passed pid=${Process.myPid()} terminal=true disposals=1 worker_cancelled=true callbacks=1 errors=0")
        }
    }
}
