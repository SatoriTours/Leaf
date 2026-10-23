package dev.leaf.testeditors
import android.os.Process
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.EditText
import dev.leaf.runtime.*
import java.io.File

class MainActivity : LeafActivity() {
    override val leafLibrary = "leaf_android_editors"
    private external fun marker(n: Int): Int
    private var ran = false
    private class FailureView(context: android.content.Context, runtime: LeafRuntime) : LeafView(context,runtime) {
        var failNextEffect = false
        override fun editNative(bytes: ByteArray) {
            super.editNative(bytes)
            if(failNextEffect) { failNextEffect=false; error("editor-1234") }
        }
    }
    override fun createLeafView(): LeafView = FailureView(this,leafRuntime)
    private fun all(v: View): List<View> = listOf(v) + if(v is ViewGroup)
        (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
    private fun editor() = all(leafView).filterIsInstance<EditText>().single()
    private fun result(s: String) { File(filesDir,"editors-result.txt").appendText(s+"\n"); android.util.Log.i("LeafEditors",s) }
    private fun click(id: String) { check((all(leafView).filterIsInstance<Button>().single { it.text.toString()==mapOf("model" to "模型更新","unrelated" to "无关更新","reset" to "重置").getValue(id) }).performClick()) }
    private fun turn() { check(leafRuntime.turn(leafView.activityMount)) }
    private fun replace(value: String) {
        val v=editor(); v.setSelection(0,v.text.length)
        check(checkNotNull(v.onCreateInputConnection(EditorInfo())).commitText(value,1))
    }
    override fun onLeafFailure(error: Throwable) { result("status=failed error=$error"); super.onLeafFailure(error) }
    override fun onLeafAttached(view: LeafView) {
        if(ran) return
        ran=true
        view.post {
            try {
                File(filesDir,"editors-result.txt").writeText("")
                check(marker(0)==1 && marker(1)==1)
                val v=editor(); check(v.text.toString()=="seed")
                v.requestFocus()
                replace("中文😀"); turn()
                check(v.text.toString()=="中文😀" && marker(2)==1)
                replace("reject"); turn()
                check(v.text.toString()=="中文😀")
                v.setSelection(2); val before=marker(2)
                click("unrelated"); turn()
                check(editor()===v && v.selectionStart==2 && marker(2)==before)
                click("model"); turn()
                check(v.text.toString()=="MODEL" && v.selectionStart==2) { "model write lost current selection: ${v.selectionStart}" }
                replace("中文😀"); turn()
                v.setSelection(0,v.text.length)
                var ic=checkNotNull(v.onCreateInputConnection(EditorInfo()))
                check(ic.setComposingText("拼",1,null)); turn()
                check(v.text.toString()=="拼")
                click("model"); turn()
                check(v.text.toString()=="拼")
                check(ic.finishComposingText()); turn()
                check(v.text.toString()=="MODEL")
                result("phase=composition pid=${Process.myPid()} reject=true unrelated_selection=2 deferred_model=MODEL finish_spans_only=true")
                v.setSelection(0,v.text.length)
                ic=checkNotNull(v.onCreateInputConnection(EditorInfo()))
                check(ic.setComposingText("拼音",1)); turn()
                val beforeReset=marker(2)
                click("reset"); turn()
                check(editor()===v && v.text.toString()=="RESET😀" && v.selectionStart==7)
                check(marker(2)==beforeReset)
                check(!ic.commitText("stale",1) && v.text.toString()=="RESET😀")
                check(!ic.commitText("stale-modern",1,null) && v.text.toString()=="RESET😀") { "old three-argument connection wrote after reset: ${v.text}" }
                result("phase=reset stable_view=true selection=7 setter_callbacks=0 stale_connection=rejected")
                v.setSelection(0,v.text.length)
                ic=checkNotNull(v.onCreateInputConnection(EditorInfo()))
                check(ic.setComposingText("暂停",1)); turn()
                check(leafRuntime.pause(view.activityMount))
                val beforePause=marker(2)
                check(ic.finishComposingText())
                check(!leafRuntime.turn(view.activityMount) && marker(2)==beforePause)
                check(leafRuntime.resume(view.activityMount)); turn()
                check(v.text.toString()=="RESET😀" && marker(2)==beforePause+1)
                check(checkNotNull(v.onCreateInputConnection(EditorInfo())).performEditorAction(EditorInfo.IME_ACTION_DONE))
                turn(); check(marker(3)==1)
                result("status=passed pid=${Process.myPid()} factories=1 init=1 pause_callbacks=0 resumed_end=1 submit=1 changes=${marker(2)}")
            } catch(e:Throwable) { result("status=failed error=$e"); android.util.Log.e("LeafEditors","probe failed",e) }
        }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        leafView.post { when {
            intent.getBooleanExtra("failure",false) -> {
                (leafView as FailureView).failNextEffect=true
                click("reset")
                var primary: String?=null
                try { leafRuntime.turn(leafView.activityMount) } catch(e:IllegalStateException) { primary=e.message }
                check(primary=="editor-1234") { "lost primary: $primary" }
                check(!leafRuntime.turn(leafView.activityMount))
                result("failure=passed pid=${Process.myPid()} primary=editor-1234 frozen=true disposals_before_close=${marker(4)}")
                finish()
            }
            intent.getBooleanExtra("noop",false) -> {
                val before=marker(2)
                val ic=checkNotNull(editor().onCreateInputConnection(EditorInfo()))
                check(ic.finishComposingText()); turn()
                result("noop_end before=$before after=${marker(2)} passed=${before==marker(2)}")
            }
            intent.getBooleanExtra("keyboard",false) -> {
                editor().requestFocus()
                (getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager).showSoftInput(editor(),InputMethodManager.SHOW_IMPLICIT)
            }
            intent.getBooleanExtra("inspect",false) -> result("inspect pid=${Process.myPid()} mount=${leafView.activityMount} focused=${editor().isFocused} value=${editor().text} changes=${marker(2)}")
            intent.getBooleanExtra("close",false) -> finish()
        } }
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations) result("terminal=true disposals=${marker(4)}")
    }
}
