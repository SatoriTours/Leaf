package dev.leaf.testcontrols

import android.content.Intent
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.ProgressBar
import android.widget.Switch
import android.widget.TextView
import dev.leaf.runtime.*
import java.io.File

class MainActivity : LeafActivity() {
    override val leafLibrary="leaf_android_controls"
    private external fun marker(n:Int):Int
    private var ran=false
    private var firstCheck:CompoundButton?=null
    private class FailureView(context:android.content.Context,runtime:LeafRuntime):LeafView(context,runtime) {
        var failNextApply=false
        override fun applyNative() {
            super.applyNative()
            if(failNextApply) { failNextApply=false;error("controls-1234") }
        }
    }
    override fun createLeafView():LeafView=FailureView(this,leafRuntime)
    private class ReentrantCheck(context:android.content.Context):CheckBox(context) {
        var afterSet:(()->Unit)?=null
        override fun setChecked(value:Boolean) { super.setChecked(value);afterSet?.invoke() }
    }
    private fun verifyPerControlGuard() {
        val left=ReentrantCheck(this);val right=CheckBox(this)
        var leftFacts=0;var rightFacts=0
        val a=CheckedBinding(left) { _,_ -> leftFacts++;true }
        val b=CheckedBinding(right) { _,_ -> rightFacts++;true }
        a.install(1) { a.write(false) };b.install(1) { b.write(false) }
        a.active(true);b.active(true)
        left.afterSet={ right.toggle() }
        a.install(1) { a.write(true) }
        check(leftFacts==0 && rightFacts==1 && right.isChecked)
        record("reentrant_native own_setter_facts=0 sibling_facts=1")
    }
    private fun all(v:View):List<View> = listOf(v) + if(v is ViewGroup)
        (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
    private fun check(label:String)=all(leafView).filterIsInstance<CompoundButton>().single { it.text.toString()==label }
    private fun record(value:String) {
        File(filesDir,"controls-result.txt").appendText(value+"\n")
        android.util.Log.i("LeafControls",value)
    }
    private fun inspect() {
        val a=check("接受");val t=check("同步开关");val reject=check("拒绝")
        check(a is CheckBox && t is Switch && reject is CheckBox)
        check(!check("禁用").isEnabled && marker(4)==0)
        val bars=all(leafView).filterIsInstance<ProgressBar>()
        check(bars.size==2 && bars.count { it.isIndeterminate }==1)
        val p=bars.single { !it.isIndeterminate }
        check(p.max==10000)
        check(all(leafView).filterIsInstance<TextView>().any { it.text.toString()=="标签 中文😀" })
        record("inspect pid=${Process.myPid()} check=${a.isChecked} toggle=${t.isChecked} reject=${reject.isChecked} changes=${marker(2)} rejections=${marker(3)} disabled=${marker(4)} progress=${p.progress}/${p.max} stable=${a===firstCheck}")
    }
    override fun onLeafAttached(view:LeafView) {
        if(ran) return
        ran=true
        view.post {
            try {
                File(filesDir,"controls-result.txt").writeText("")
                check(marker(0)==1 && marker(1)==1)
                verifyPerControlGuard()
                firstCheck=check("接受")
                check(!check("接受").isChecked && !check("同步开关").isChecked)
                inspect()
                record("ready pid=${Process.myPid()} factories=1 init=1")
            } catch(e:Throwable) { record("status=failed error=$e");android.util.Log.e("LeafControls","probe failed",e) }
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent)
        leafView.post {
            try {
                when {
                    intent.getBooleanExtra("failure",false) -> {
                        val old=check("接受");val accepted=old.isChecked
                        val progress=all(leafView).filterIsInstance<ProgressBar>().single { !it.isIndeterminate }.progress
                        val before=marker(2)
                        (leafView as FailureView).failNextApply=true
                        val button=all(leafView).filterIsInstance<Button>().single { it !is CompoundButton && it.text.toString()=="程序更新" }
                        check(button.performClick())
                        var primary:String?=null
                        try { leafRuntime.turn(leafView.activityMount) } catch(e:IllegalStateException) { primary=e.message }
                        check(primary=="controls-1234") { "primary lost: $primary" }
                        check(check("接受")!==old && check("接受").isChecked==accepted && check("同步开关").isChecked==accepted)
                        check(all(leafView).filterIsInstance<ProgressBar>().single { !it.isIndeterminate }.progress==progress)
                        val staleBefore=old.isChecked
                        val handled=old.performClick()
                        check(old.isChecked!=staleBefore) { "stale native checkbox did not toggle" }
                        check(leafRuntime.turn(leafView.activityMount)) { "turn rejected after accepted replay" }
                        record("stale_native toggled=true click_handled=$handled")
                        check(marker(2)==before && check("接受").isChecked==accepted)
                        check(all(leafView).filterIsInstance<Button>().single { it !is CompoundButton && it.text.toString()=="程序更新" }.performClick())
                        check(leafRuntime.turn(leafView.activityMount))
                        check(check("接受").isChecked!=accepted && marker(2)==before)
                        firstCheck=check("接受")
                        inspect()
                        record("failure=passed primary=controls-1234 accepted_replayed=true old_view=rejected retry=passed setter_callbacks=0")
                        record("status=passed pid=${Process.myPid()} factories=${marker(0)} init=${marker(1)}")
                    }
                    intent.getBooleanExtra("model",false) -> {
                        val before=marker(2)
                        check(all(leafView).filterIsInstance<Button>().single { it !is CompoundButton && it.text.toString()=="程序更新" }.performClick())
                        check(leafRuntime.turn(leafView.activityMount))
                        check(marker(2)==before) { "programmatic checked setter echoed" }
                        inspect();record("model setter_callbacks=0")
                    }
                    intent.getBooleanExtra("pause",false) -> {
                        check(leafRuntime.pause(leafView.activityMount))
                        val before=marker(2)
                        check("接受").isChecked=!check("接受").isChecked
                        check(marker(2)==before)
                        check(leafRuntime.resume(leafView.activityMount))
                        check(leafRuntime.turn(leafView.activityMount))
                        check(marker(2)==before+1)
                        inspect();record("pause callbacks=0 resume_callbacks=1")
                    }
                    intent.getBooleanExtra("inspect",false) -> inspect()
                    intent.getBooleanExtra("close",false) -> finish()
                }
            } catch(e:Throwable) { record("status=failed error=$e");android.util.Log.e("LeafControls","probe failed",e) }
        }
    }
    override fun onLeafFailure(error:Throwable) { record("status=failed error=$error");super.onLeafFailure(error) }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations) record("terminal=true disposals=${marker(5)}")
    }
}
