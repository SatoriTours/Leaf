package dev.leaf.testsqlite
import android.content.Intent
import android.os.Bundle
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import dev.leaf.runtime.*
import java.io.File
class MainActivity:LeafActivity() {
    override val leafLibrary="leaf_android_sqlite"
    private external fun configure(path:ByteArray,sql:ByteArray):Int
    private external fun marker(which:Int):Long
    private var attached=false
    override fun onCreate(state:Bundle?) {
        System.loadLibrary(leafLibrary)
        NativeBridge.initialize()
        // Fixture supplies Android's private app path and asset migration; this
        // does not stand in for the still-unimplemented generic resource API.
        val sql=assets.open("migrations/001-notes.sql").use {it.readBytes()}
        check(configure(NativeBridge.encodeUtf8(File(filesDir,"数据/notes.sqlite3").absolutePath),sql)==0)
        super.onCreate(state)
    }
    private fun all(v:View):List<View> = listOf(v)+if(v is ViewGroup)(0 until v.childCount).flatMap {all(v.getChildAt(it))} else emptyList()
    private fun record(s:String) {
        val line="$s pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${leafView.activityMount} factory=${marker(0)} init=${marker(1)} opens=${marker(3)} id=${marker(4)} engine=${marker(5)}/${marker(6)} same=${marker(7)}"
        File(filesDir,"sqlite-result.txt").appendText(line+"\n")
        android.util.Log.i("LeafSqlite",line)
    }
    private fun snapshot(s:String) {
        check(marker(0)==1L && marker(1)==1L && marker(5)==3054001L && marker(6)==3054001L && marker(7)==1L)
        val text=all(leafView).filterIsInstance<TextView>().single {it !is Button && it.text.startsWith("记录=")}.text.toString()
        check(text=="记录=${marker(4)}")
        record(s+" label="+text)
    }
    override fun onLeafAttached(view:LeafView) {
        if(attached)return
        attached=true
        leafView.postDelayed({try {snapshot("ready")}catch(e:Throwable){onLeafFailure(e)}},150)
    }
    override fun onLeafFailure(error:Throwable) {File(filesDir,"sqlite-result.txt").appendText("status=failed pid=${Process.myPid()} error=$error\n");super.onLeafFailure(error)}
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent)
        leafView.postDelayed({try {when(intent.getStringExtra("action")) {
            "snapshot" -> snapshot("observed")
            "recreate" -> {snapshot("before_recreate");recreate()}
            "finish" -> finish()
        }}catch(e:Throwable){onLeafFailure(e)}},150)
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations)File(filesDir,"sqlite-result.txt").appendText("terminal=true pid=${Process.myPid()} disposals=${marker(2)}\n")
    }
}
