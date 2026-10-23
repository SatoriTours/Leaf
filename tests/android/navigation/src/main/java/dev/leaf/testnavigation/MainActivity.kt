package dev.leaf.testnavigation

import android.content.Intent
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import dev.leaf.runtime.*
import java.io.File

class MainActivity:LeafActivity() {
    override val leafLibrary="leaf_android_navigation"
    private external fun marker(which:Int):Int
    private var attached=false
    private class FailureView(context:android.content.Context,runtime:LeafRuntime):LeafView(context,runtime) {
        var failNext=false
        override fun applyNative() {
            super.applyNative()
            if(failNext) {failNext=false;error("navigation-1234")}
        }
    }
    override fun createLeafView():LeafView=FailureView(this,leafRuntime)
    private fun all(v:View):List<View> = listOf(v)+if(v is ViewGroup)
        (0 until v.childCount).flatMap {all(v.getChildAt(it))} else emptyList()
    private fun button(label:String)=all(leafView).filterIsInstance<Button>().single {it.text==label}
    private fun label()=all(leafView).filterIsInstance<TextView>().single {it !is Button && it.text.contains(" 状态=")}.text
    private fun record(s:String) {
        File(filesDir,"navigation-result.txt").appendText(s+"\n")
        android.util.Log.i("LeafNavigation",s)
    }
    override fun onLeafFailure(error:Throwable) {
        record("status=failed pid=${Process.myPid()} error=$error");super.onLeafFailure(error)
    }
    private fun later(action:()->Unit) {
        leafView.postDelayed({try {action()}catch(e:Throwable){onLeafFailure(e)}},150)
    }
    private fun turn() {check(leafRuntime.turn(leafView.activityMount))}
    private fun snapshot(stage:String) {
        record("$stage pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${leafView.activityMount} depth=${marker(2)} factory=${marker(0)} init=${marker(3)},${marker(4)},${marker(5)} state=${marker(6)} label=${label()} can_back=${leafView.canNavigateBack()}")
    }
    override fun onLeafAttached(view:LeafView) {
        if(attached)return
        attached=true
        later {
            check(marker(0)==1 && marker(3)==1)
            if(view.activityMount==1L)File(filesDir,"navigation-result.txt").writeText("")
            snapshot("ready")
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent);setIntent(intent)
        later {
            when(intent.getStringExtra("action")) {
                "snapshot" -> snapshot("observed")
                "increment" -> {check(button("增加状态").performClick());turn();snapshot("increment=passed")}
                "push" -> {val depth=marker(2);check(button("打开下一页").performClick());turn();check(marker(2)==depth+1);snapshot("push=passed")}
                "cancel" -> {
                    val depth=marker(2);val before=label().toString()
                    val request=checkNotNull(leafView.beginBack())
                    check(marker(2)==depth)
                    check(leafView.cancelBack(request));turn()
                    check(marker(2)==depth && label().toString()==before)
                    check(!leafView.confirmBack(request));snapshot("cancel=passed")
                }
                "stale" -> {
                    val request=checkNotNull(leafView.beginBack())
                    check(button("打开下一页").performClick());turn()
                    val depth=marker(2)
                    check(!leafView.confirmBack(request));turn();check(marker(2)==depth)
                    snapshot("stale=passed")
                }
                "pause" -> {
                    val depth=marker(2);val request=checkNotNull(leafView.beginBack())
                    check(leafRuntime.pause(leafView.activityMount))
                    check(!leafView.confirmBack(request) && !leafRuntime.turn(leafView.activityMount))
                    check(leafRuntime.resume(leafView.activityMount))
                    check(leafView.cancelBack(request));turn();check(marker(2)==depth)
                    snapshot("pause=passed")
                }
                "failure" -> {
                    val depth=marker(2);val before=label().toString()
                    val request=checkNotNull(leafView.beginBack())
                    check(leafView.confirmBack(request))
                    check(marker(2)==depth) {"callback synchronously changed business history"}
                    (leafView as FailureView).failNext=true
                    var primary=false
                    try {turn()}catch(e:IllegalStateException) {primary=e.message=="navigation-1234"}
                    check(primary && marker(2)==depth && label().toString()==before)
                    turn();check(marker(2)==depth)
                    check(!leafView.confirmBack(request))
                    val retry=checkNotNull(leafView.beginBack());check(leafView.confirmBack(retry));turn()
                    check(marker(2)==depth-1)
                    snapshot("failure=passed primary=1234 idle_retry=0 fresh_retry=1")
                }
                "recreate" -> {snapshot("before_recreate");recreate()}
                "finish" -> finish()
            }
        }
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations)record("terminal=true disposals=${marker(1)}")
    }
}
