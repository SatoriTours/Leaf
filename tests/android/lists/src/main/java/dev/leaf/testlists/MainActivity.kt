package dev.leaf.testlists

import android.content.Intent
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import androidx.recyclerview.widget.RecyclerView
import dev.leaf.runtime.*
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity:LeafActivity() {
    override val leafLibrary="leaf_android_lists"
    private external fun marker(which:Int):Int
    private var ran=false
    private var old:Button?=null
    private var clicked=0
    private class FailureView(context:android.content.Context,runtime:LeafRuntime):LeafView(context,runtime) {
        var failNext=false
        var applies=0
        override fun applyNative() {
            applies++;super.applyNative()
            if(failNext) {failNext=false;error("lists-1234")}
        }
    }
    override fun createLeafView():LeafView=FailureView(this,leafRuntime)
    private fun all(v:View):List<View> = listOf(v) + if(v is ViewGroup)
        (0 until v.childCount).flatMap { all(v.getChildAt(it)) } else emptyList()
    private fun recycler()=all(leafView).filterIsInstance<RecyclerView>().single()
    private fun record(value:String) {
        File(filesDir,"lists-result.txt").appendText(value+"\n")
        android.util.Log.i("LeafLists",value)
    }
    override fun onLeafFailure(error:Throwable) {
        record("status=failed error=$error");super.onLeafFailure(error)
    }
    private fun verifyMetadata() {
        fun measure(variable:Boolean) {
            val b=ByteBuffer.allocate(256).order(ByteOrder.LITTLE_ENDIAN)
            b.putInt(0x3456414c);repeat(3) {b.putLong(0)};b.putInt(1);b.putInt(0)
            b.putInt(0);b.putLong(999);b.putLong(if(variable)0 else 100);b.putInt(0)
            b.putInt(if(variable)11 else 0);b.putInt(1);b.putInt(0)
            repeat(4) {b.putInt(0)};b.putInt(0);b.putDouble(0.0)
            b.putInt(if(variable)1 else 0)
            if(variable) {
                b.putLong(1);b.putInt(100000);b.putInt(1)
                b.putDouble(0.0);b.putDouble(24.0);b.putInt(1)
                b.putInt(0)
            } else {
                b.putInt(1);b.putLong(100);b.putLong(1);b.putInt(0);b.putInt(0) // legal empty item key
            }
            b.putInt(0);b.putInt(0)
            leafView.measureNative(b.array().copyOf(b.position()),300.0,96.0)
        }
        var failures=0
        for(variable in listOf(true,false)) {
            val name=if(variable)"variable_metadata" else "empty_row_key"
            try {measure(variable);record("$name=passed")}
            catch(e:IllegalArgumentException) {failures++;record("$name=failed error=$e")}
        }
        check(failures==0) {"Legal typed metadata rejected: $failures"}
    }
    private fun inspect() {
        val r=recycler();val buttons=all(r).filterIsInstance<Button>()
        check(r.adapter!!.itemCount in 1..10 && buttons.isNotEmpty())
        check(marker(0)==1 && marker(1)==1 && marker(2)==1)
        record("inspect pid=${Process.myPid()} physical=${r.adapter!!.itemCount} children=${r.childCount} builds=${marker(3)} renders=${marker(2)} clicks=${marker(4)} offset=${r.computeVerticalScrollOffset()} labels=${buttons.map { it.text }}")
    }
    override fun onLeafAttached(view:LeafView) {
        if(ran)return
        ran=true
        view.post {
            try {
                File(filesDir,"lists-result.txt").writeText("")
                check(leafRuntime.resume(view.activityMount))
                repeat(3) { check(leafRuntime.turn(view.activityMount)) }
                // RecyclerView layout happens on the next Android frame.
                view.postDelayed({
                    try {
                        verifyMetadata();inspect();old=all(recycler()).filterIsInstance<Button>().first()
                        record("ready pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${view.activityMount}")
                    } catch(e:Throwable) {onLeafFailure(e)}
                },100)
            } catch(e:Throwable) {onLeafFailure(e)}
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent);setIntent(intent)
        leafView.postDelayed({
            try {
                val mount=leafView.activityMount
                if(intent.getBooleanExtra("inspect",false))inspect()
                if(intent.getBooleanExtra("scroll",false)) {
                    recycler().scrollBy(0,(240*resources.displayMetrics.density).toInt())
                    repeat(3) {check(leafRuntime.turn(mount))}
                    leafView.postDelayed({try {inspect();record("scroll=passed")}catch(e:Throwable){onLeafFailure(e)}},100)
                }
                if(intent.getBooleanExtra("stale",false)) {
                    val before=marker(4);old?.performClick();check(leafRuntime.turn(mount));check(marker(4)==before)
                    record("stale=passed")
                }
                if(intent.getBooleanExtra("click",false)) {
                    val before=marker(4)
                    all(recycler()).filterIsInstance<Button>().first {it.isShown}.performClick()
                    check(leafRuntime.turn(mount));check(marker(4)==before+1);clicked=marker(4)
                    record("click=passed count=$clicked")
                }
                if(intent.getBooleanExtra("pause",false)) {
                    val r=recycler();val before=r.computeVerticalScrollOffset()
                    check(leafRuntime.pause(mount));r.scrollBy(0,120)
                    check(!leafRuntime.turn(mount));check(leafRuntime.resume(mount));check(leafRuntime.turn(mount))
                    check(r.computeVerticalScrollOffset()==before);record("pause=passed")
                }
                if(intent.getBooleanExtra("failure",false)) {
                    repeat(3) {check(leafRuntime.turn(mount))}
                    val r=recycler();val before=r.computeVerticalScrollOffset()
                    val originals=all(r).filterIsInstance<Button>()
                    r.scrollBy(0,(24*resources.displayMetrics.density).toInt())
                    val v=leafView as FailureView;v.failNext=true
                    var primary=false
                    try {leafRuntime.turn(mount)} catch(e:IllegalStateException) {primary=e.message=="lists-1234"}
                    check(primary && r.computeVerticalScrollOffset()==before)
                    check(all(r).filterIsInstance<Button>()==originals)
                    val calls=v.applies;check(leafRuntime.turn(mount));check(v.applies==calls)
                    r.scrollBy(0,(48*resources.displayMetrics.density).toInt());check(leafRuntime.turn(mount))
                    check(r.computeVerticalScrollOffset()>before)
                    record("failure=passed primary=1234 same_views=true idle_retry=0")
                }
                if(intent.getBooleanExtra("huge",false)) {
                    recycler().scrollBy(0,Int.MAX_VALUE/4)
                    repeat(3) {check(leafRuntime.turn(mount))}
                    leafView.postDelayed({try {inspect();record("huge=passed")}catch(e:Throwable){onLeafFailure(e)}},100)
                }
                if(intent.getBooleanExtra("finish",false))finish()
            } catch(e:Throwable) {onLeafFailure(e)}
        },100)
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations)record("terminal=true disposals=${marker(5)}")
    }
}
