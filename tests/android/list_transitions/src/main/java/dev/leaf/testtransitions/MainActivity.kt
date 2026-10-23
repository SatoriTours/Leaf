package dev.leaf.testtransitions

import android.content.Intent
import android.os.Process
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import androidx.recyclerview.widget.RecyclerView
import dev.leaf.runtime.*
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

class MainActivity:LeafActivity() {
    override val leafLibrary="leaf_android_transitions"
    private external fun marker(which:Int):Int
    private var attached=false
    private var old:Button?=null
    private var anchorTop=0
    private class FailureView(context:android.content.Context,runtime:LeafRuntime):LeafView(context,runtime) {
        var failNext=false
        override fun applyNative() {
            super.applyNative()
            if(failNext) {failNext=false;error("transitions-1234")}
        }
    }
    override fun createLeafView():LeafView=FailureView(this,leafRuntime)
    private fun all(v:View):List<View> = listOf(v)+if(v is ViewGroup)
        (0 until v.childCount).flatMap {all(v.getChildAt(it))} else emptyList()
    private fun recycler()=all(leafView).filterIsInstance<RecyclerView>().single()
    private fun buttons()=all(recycler()).filterIsInstance<Button>()
    private fun row(id:Int)=buttons().single {it.text.startsWith("行 $id 中文")}
    private fun top(v:View):Int {
        val point=IntArray(2);v.getLocationInWindow(point)
        val parent=IntArray(2);recycler().getLocationInWindow(parent)
        return point[1]-parent[1]
    }
    private fun turns() {repeat(6) {check(leafRuntime.turn(leafView.activityMount))}}
    private fun record(s:String) {
        File(filesDir,"transitions-result.txt").appendText(s+"\n")
        android.util.Log.i("LeafTransitions",s)
    }
    override fun onLeafFailure(error:Throwable) {
        record("status=failed pid=${Process.myPid()} error=$error");super.onLeafFailure(error)
    }
    private fun later(action:()->Unit) {
        leafView.postDelayed({try {action()}catch(e:Throwable){onLeafFailure(e)}},150)
    }
    override fun onLeafAttached(view:LeafView) {
        if(attached)return
        attached=true
        later {
            check(leafRuntime.resume(view.activityMount));turns()
            later {
                check(marker(0)==1 && marker(1)==1)
                if(marker(6)==0) {
                    File(filesDir,"transitions-result.txt").writeText("")
                    val scale=resources.displayMetrics.density
                    check(abs(row(1).height-(96*scale).roundToInt())<=1)
                    check(abs(top(row(2))-(144*scale).roundToInt())<=1)
                    record("ready pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${view.activityMount} physical=${recycler().adapter!!.itemCount} renders=${marker(2)}")
                } else {
                    if(marker(6)==4)check(row(0).text.endsWith("大")) {"row State was lost across Activity recreate"}
                    record("reattached pid=${Process.myPid()} owner=${leafRuntime.owner} mount=${view.activityMount} phase=${marker(6)} factory=${marker(0)} init=${marker(1)} row0=${row(0).text}")
                }
            }
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent);setIntent(intent)
        later {
            if(intent.getBooleanExtra("anchor",false)) {
                recycler().scrollBy(0,(202*resources.displayMetrics.density).roundToInt());turns()
                later {
                    val scale=resources.displayMetrics.density
                    old=row(2);anchorTop=top(row(3))
                    check(abs(anchorTop+10*scale)<=1)
                    val renders=marker(2);val changes=marker(4)
                    check(old!!.performClick());turns()
                    later {
                        check(row(2)===old)
                        check(abs(top(row(3))-anchorTop)<=1) {"variable anchor moved: $anchorTop -> ${top(row(3))}"}
                        check(abs(row(2).height-96*scale)<=1)
                        check(marker(2)==renders && marker(4)==changes+1)
                        record("anchor=passed pid=${Process.myPid()} key3_top_px=$anchorTop row2_height=${row(2).height} same_view=true parent_renders=$renders physical=${recycler().adapter!!.itemCount}")
                    }
                }
            }
            if(intent.getBooleanExtra("source",false)) {
                val previous=marker(6)
                all(leafView).filterIsInstance<Button>().single {it.text=="下个数据源"}.performClick()
                turns()
                later {
                    val phase=marker(6);check(phase==(previous+1)%5)
                    val r=recycler();val rows=buttons()
                    check(r.adapter!!.itemCount<=8)
                    if(phase==1) {
                        val changes=marker(4);old?.performClick();turns();check(marker(4)==changes)
                        check(rows.all {!it.text.startsWith("行 2 中文")})
                    }
                    if(phase==2) {
                        check(rows.map {it.text.toString().split(' ')[1]}.toSet()==setOf("0","1","2"))
                        check(r.computeVerticalScrollOffset()==0)
                    }
                    if(phase==3)check(rows.isEmpty() && r.adapter!!.itemCount==0 && r.computeVerticalScrollRange()==0)
                    if(phase==4)check(rows.any {it.text.startsWith("行 0 中文")})
                    check(marker(0)==1 && marker(1)==1)
                    record("source=passed pid=${Process.myPid()} phase=$phase physical=${r.adapter!!.itemCount} offset=${r.computeVerticalScrollOffset()} labels=${rows.map {it.text}}")
                }
            }
            if(intent.getBooleanExtra("recreate",false)) {
                check(row(0).performClick());turns()
                check(row(0).text.endsWith("大"));recreate()
            }
            if(intent.getBooleanExtra("failure",false)) {
                check(marker(6)==4)
                val view=leafView as FailureView
                view.failNext=true
                all(leafView).filterIsInstance<Button>().single {it.text=="下个数据源"}.performClick()
                var primary=false
                try {leafRuntime.turn(view.activityMount)} catch(e:IllegalStateException) {primary=e.message=="transitions-1234"}
                check(primary && marker(6)==4) {"source failure did not preserve accepted State"}
                turns()
                later {
                    check(row(0).text.endsWith("大"))
                    check(marker(0)==1 && marker(1)==1)
                    record("failure=passed pid=${Process.myPid()} primary=1234 phase=${marker(6)} row0=${row(0).text} next_turn=true")
                }
            }
            if(intent.getBooleanExtra("finish",false))finish()
        }
    }
    override fun onDestroy() {
        super.onDestroy()
        if(!isChangingConfigurations)record("terminal=true disposals=${marker(5)}")
    }
}
