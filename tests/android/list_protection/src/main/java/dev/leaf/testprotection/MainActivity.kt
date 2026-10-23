package dev.leaf.testprotection

import android.content.Intent
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.widget.EditText
import androidx.recyclerview.widget.RecyclerView
import dev.leaf.runtime.*
import java.io.File

/** Real Views/spans fixture. InputConnection calls are explicit fixture input,
 * separate from the actual adb tap/swipe recorded by the device driver. */
class MainActivity:LeafActivity() {
    override val leafLibrary="leaf_android_protection"
    private external fun marker(which:Int):Int
    private var ran=false
    private var editor:EditText?=null
    private var connection:InputConnection?=null
    private class FailureView(context:android.content.Context,runtime:LeafRuntime):LeafView(context,runtime) {
        var failNext=false
        override fun applyNative() {
            super.applyNative()
            if(failNext) {failNext=false;error("protect-business-1234")}
        }
    }
    override fun createLeafView():LeafView=FailureView(this,leafRuntime)
    private fun all(v:View):List<View> = listOf(v) + if(v is ViewGroup)
        (0 until v.childCount).flatMap {all(v.getChildAt(it))} else emptyList()
    private fun recycler()=all(leafView).filterIsInstance<RecyclerView>().single()
    private fun record(value:String) {
        File(filesDir,"protection-result.txt").appendText(value+"\n")
        android.util.Log.i("LeafProtection",value)
    }
    override fun onLeafFailure(error:Throwable) {
        record("status=failed error=$error");super.onLeafFailure(error)
    }
    private fun turns() {repeat(3) {check(leafRuntime.turn(leafView.activityMount))}}
    private fun verifyRetained(label:String,focused:Boolean,requireComposition:Boolean=true) {
        val e=checkNotNull(editor)
        check(all(recycler()).any {it===e}) {"Protected editor was removed"}
        check(e.isAttachedToWindow && e.isFocused==focused) {"Focus/attachment lost: ${e.isFocused}"}
        val composing=BaseInputConnection.getComposingSpanStart(e.text)>=0
        if(requireComposition)check(composing) {"Actual composing span lost"}
        check(marker(0)==1 && marker(1)==1 && marker(2)==1)
        if(label=="scroll" || label=="blur")check(recycler().computeVerticalScrollOffset()==100000) {
            "Protected focus changed the accepted scroll target: ${recycler().computeVerticalScrollOffset()}"
        }
        record("$label=passed pid=${Process.myPid()} focused=${e.isFocused} composing=$composing physical=${recycler().adapter!!.itemCount} offset=${recycler().computeVerticalScrollOffset()} builds=${marker(3)} changes=${marker(4)} same_view=true")
    }
    override fun onLeafAttached(view:LeafView) {
        if(ran)return
        ran=true
        view.post {
            try {
                File(filesDir,"protection-result.txt").writeText("")
                check(leafRuntime.resume(view.activityMount));turns()
                view.postDelayed({try {
                    editor=all(recycler()).filterIsInstance<EditText>().first {it.text.startsWith("行 0 ")}
                    record("ready pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${view.activityMount} editors=${all(recycler()).filterIsInstance<EditText>().size}")
                } catch(e:Throwable) {onLeafFailure(e)}},150)
            } catch(e:Throwable) {onLeafFailure(e)}
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent);setIntent(intent)
        leafView.postDelayed({try {
            if(intent.getBooleanExtra("compose",false)) {
                recycler().scrollBy(0,-Int.MAX_VALUE/4);turns()
                val e=checkNotNull(editor)
                check(e.requestFocus());e.setSelection(e.text.length)
                connection=e.onCreateInputConnection(EditorInfo())
                check(checkNotNull(connection).setComposingText("组合😀",1))
                turns();verifyRetained("compose",true)
            }
            if(intent.getBooleanExtra("scroll",false)) {
                recycler().scrollBy(0,-Int.MAX_VALUE/4);turns()
                recycler().scrollBy(0,(480*resources.displayMetrics.density).toInt());turns()
                leafView.postDelayed({try {verifyRetained("scroll",true)} catch(e:Throwable) {onLeafFailure(e)}},150)
            }
            if(intent.getBooleanExtra("gesture",false)) {
                check(recycler().computeVerticalScrollOffset()>0)
                verifyRetained("gesture",true,false)
            }
            if(intent.getBooleanExtra("blur",false)) {
                leafView.isFocusableInTouchMode=true;check(leafView.requestFocus())
                turns();verifyRetained("blur",false)
            }
            if(intent.getBooleanExtra("release",false)) {
                check(checkNotNull(connection).finishComposingText());turns()
                leafView.postDelayed({try {
                    val e=checkNotNull(editor)
                    check(all(recycler()).none {it===e}) {"Released offscreen row was retained"}
                    check(!e.isAttachedToWindow)
                    val changes=marker(4)
                    connection?.commitText("stale",1);turns();check(marker(4)==changes)
                    record("release=passed old_detached=true stale_delivery=0 changes=$changes physical=${recycler().adapter!!.itemCount}")
                } catch(e:Throwable) {onLeafFailure(e)}},150)
            }
            if(intent.getBooleanExtra("businessFailure",false)) {
                recycler().scrollBy(0,(480*resources.displayMetrics.density).toInt())
                check(leafRuntime.turn(leafView.activityMount)) // Project and queue new rows.
                (leafView as FailureView).failNext=true
                var primary=false
                try {leafRuntime.turn(leafView.activityMount)}
                catch(e:IllegalStateException) {primary=e.message=="protect-business-1234"}
                check(primary) {"Lost original business apply error"}
                check(leafRuntime.turn(leafView.activityMount)) {"Protection callback broke accepted replay"}
                check(marker(0)==1 && marker(1)==1)
                record("business_failure=passed primary=1234 ordinary_turn_after_replay=true factory=1 init=1")
            }
            if(intent.getBooleanExtra("finish",false))finish()
        } catch(e:Throwable) {onLeafFailure(e)}},100)
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations)record("terminal=true disposals=${marker(5)}")
    }
}
