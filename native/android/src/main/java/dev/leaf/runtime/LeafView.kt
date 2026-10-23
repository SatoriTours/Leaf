package dev.leaf.runtime

import android.content.Context
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.CompoundButton
import android.widget.ProgressBar
import android.widget.FrameLayout
import android.widget.TextView
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import kotlin.math.roundToInt

/** Platform views only. The managed Runtime owns all business descriptions and
 * callbacks. This class consumes incremental LAV1 ops and explicit DIP boxes. */
open class LeafView(context: Context, private val runtime: LeafRuntime) : FrameLayout(context) {
    private data class Op(val tag: Int, val handle: Long, val parent: Long, val index: Int,
                          val kind: Int, val enabled: Boolean, val click: Boolean,
                          val id: String, val label: String, val value: String = "", val hint: String = "",
                          val checked:Boolean=false,val progress:Double=0.0,
                          val list:ListMeta?=null,val row:RowBinding?=null,
                          val back:Boolean=false,val navigation:NavigationMeta?=null)
    private data class NavigationMeta(val router:Long,val history:Long,val current:Long,
                                      val previous:Long,val depth:Int,val binding:Long)
    /** Captured accepted identity; no platform history or business callback. */
    class BackRequest internal constructor(internal val session:Long,internal val mount:Long,
        internal val handle:Long,internal val revision:Long,internal val binding:Long,
        internal val router:Long,internal val history:Long,internal val current:Long,
        internal val previous:Long,internal val depth:Int,internal val request:Long)
    private data class ListMeta(val source:Long,val count:Int,val mode:Int,val height:Double,
                                val estimate:Double,val overscan:Int)
    private data class RowBinding(val list:Long,val source:Long,val index:Int,val key:String)
    private data class Projection(val handle:Long,val source:Long,val token:Long,val offset:Double,
                                  val total:Double,val height:Double,val first:Int,val finish:Int,val protected:List<Int>)
    private data class Box(val handle: Long, val values: DoubleArray)
    private data class Effect(val kind: Int, val value: String, val checked: Boolean,
                              val anchor: Int, val caret: Int, val force: Boolean)
    private data class Write(val handle: Long, val binding: Long, val effects: List<Effect>)
    private data class Frame(val session: Long, val mount: Long, val revision: Long,
                             val ops: List<Op>, val boxes: List<Box>, val writes: List<Write>,
                             val lists:List<Projection>)
    private data class Plan(val frame: Frame, val specs: LinkedHashMap<Long, Op>,
                            val created: Map<Long, View>,val intents:Map<Long,Long>)
    private val views = LinkedHashMap<Long, View>()
    private var specs = linkedMapOf<Long, Op>()
    private var prepared: Plan? = null
    private var session = 0L
    private var eventMount = 0L
    private var observedRevision = 0L
    private var sequence = 0L
    private var editorsActive = false
    private data class Protection(val binding:Long,val reasons:Int)
    private val protection = LinkedHashMap<Long,Protection>()
    private var attemptIntents=emptyMap<Long,Long>()
    var activityMount: Long = 0L
        internal set
    private val density get() = resources.displayMetrics.density.toDouble()

    private fun parse(bytes: ByteArray): Frame {
        require(bytes.size in 36..67108864)
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun int(): Int { require(b.remaining() >= 4); return b.int }
        fun long(): Long { require(b.remaining() >= 8); return b.long }
        fun number():Double {require(b.remaining()>=8);return b.double.also {require(it.isFinite())}}
        fun string(): String {
            val n = int(); require(n in 0..1048576 && n <= b.remaining())
            val data = ByteArray(n); b.get(data)
            return NativeBridge.decodeUtf8(data)
        }
        val magic = int(); require(magic in listOf(0x3156414c,0x3256414c,0x3356414c,0x3456414c,0x3556414c))
        val editors = magic != 0x3156414c
        val navigation = magic == 0x3556414c
        val controls = magic == 0x3356414c || magic == 0x3456414c || navigation
        val lists=magic==0x3456414c || navigation
        val sid = long(); val mount = long(); val revision = long()
        val count = int(); val geometryCount = int()
        require(count in 0..40064 && geometryCount in 0..10000)
        val ops = ArrayList<Op>(count)
        repeat(count) {
            val tag = int(); val handle = long(); val parent = long(); val index = int()
            val kind = int(); val enabled = int(); val click = int()
            require(tag in 0..3 && handle != 0L && index >= 0 && kind in 0..(if(navigation)12 else 11))
            require(enabled in 0..1 && click in 0..1)
            val id = string(); val label = string()
            val value = if (editors) string() else ""
            val hint = if (editors) string() else ""
            val checked=if(controls) int() else 0
            require(checked in 0..1)
            val progress=if(controls) { require(b.remaining()>=8); b.double } else 0.0
            require(progress.isFinite() && progress in 0.0..100.0)
            var list:ListMeta?=null
            var row:RowBinding?=null
            if(lists) {
                val hasList=int();require(hasList in 0..1)
                if(hasList==1) {
                    val source=long();val count=int();val mode=int()
                    val height=number();val estimate=number();val overscan=int()
                    require(source!=0L && count in 0..100_000 && mode in 0..1 &&
                        (if(mode==0)height>0 && height<=1_000_000 else height==0.0) &&
                        estimate>0 && estimate<=1_000_000 && overscan in 0..32)
                    list=ListMeta(source,count,mode,height,estimate,overscan)
                }
                val hasRow=int();require(hasRow in 0..1)
                if(hasRow==1) {
                    val listHandle=long();val source=long();val itemIndex=int();val key=string()
                    require(listHandle!=0L && source!=0L && itemIndex>=0)
                    row=RowBinding(listHandle,source,itemIndex,key)
                }
            }
            val back=if(navigation)int() else 0
            val hasNavigation=if(navigation)int() else 0
            require(back in 0..1 && hasNavigation in 0..1)
            val nav=if(hasNavigation==1) {
                val router=long();val history=long();val current=long();val previous=long()
                val depth=int();val binding=long()
                require(router!=0L && history!=0L && current!=0L && binding!=0L && depth in 1..10000)
                require(if(depth==1)previous==0L else previous!=0L &&
                    java.lang.Long.compareUnsigned(previous,current)<0)
                NavigationMeta(router,history,current,previous,depth,binding)
            } else null
            if(tag in 0..1)require((kind==12)==(nav!=null) && (back==0 || kind==12))
            ops += Op(tag, handle, parent, index, kind, enabled == 1, click == 1, id, label, value, hint,checked==1,progress,list,row,back==1,nav)
        }
        val boxes = ArrayList<Box>(geometryCount)
        repeat(geometryCount) {
            val handle = long(); require(b.remaining() >= 64)
            val numbers = DoubleArray(8) { b.double }
            require(numbers.all { it.isFinite() } && numbers[2] >= 0 && numbers[3] >= 0 &&
                    numbers[6] >= 0 && numbers[7] >= 0)
            boxes += Box(handle, numbers)
        }
        val writes = arrayListOf<Write>()
        if (editors) {
            val n = int(); require(n in 0..10000)
            repeat(n) {
                val handle = long(); val binding = long(); val count = int()
                require(handle != 0L && binding > 0 && count in 0..3)
                val effects = arrayListOf<Effect>()
                repeat(count) {
                    val kind = int(); val value = string(); val checked = int()
                    val anchor = int(); val caret = int(); val force = int()
                    require(kind in 0..3 && checked in 0..1 && anchor >= 0 && caret >= 0 && force in 0..1)
                    effects += Effect(kind, value, checked == 1, anchor, caret, force == 1)
                }
                writes += Write(handle, binding, effects)
            }
        }
        val projections=arrayListOf<Projection>()
        if(lists) {
            val n=int();require(n in 0..10000)
            repeat(n) {
                val handle=long();val source=long();val token=long()
                val offset=number();val total=number();val height=number()
                val first=int();val finish=int();val protectedCount=int()
                require(handle!=0L && source!=0L && token!=0L && offset>=0 && total>=0 && height>=0 &&
                    offset<=(total-height).coerceAtLeast(0.0) && first>=0 && finish>=first && protectedCount in 0..10000)
                val protected=List(protectedCount) {int().also {require(it>=0)}}
                projections+=Projection(handle,source,token,offset,total,height,first,finish,protected)
            }
        }
        require(!b.hasRemaining())
        return Frame(sid, mount, revision, ops, boxes, writes,projections)
    }

    /** This first host supports one unambiguous navigation container. Multiple
     * eligible stacks leave system back to the Activity instead of guessing. */
    fun canNavigateBack():Boolean = specs.values.filter {it.kind==12}.singleOrNull()?.let {
        it.enabled && it.back && (it.navigation?.depth ?: 0)>1
    } ?: false

    fun beginBack():BackRequest? {
        if(!canNavigateBack())return null
        val op=specs.values.single {it.kind==12}
        val nav=checkNotNull(op.navigation)
        val request=BackRequest(session,eventMount,op.handle,observedRevision,nav.binding,
            nav.router,nav.history,nav.current,nav.previous,nav.depth,runtime.nextBackRequest())
        return if(backFact(request,0))request else null
    }
    fun cancelBack(request:BackRequest):Boolean = backFact(request,1)
    fun confirmBack(request:BackRequest):Boolean = backFact(request,2)
    private fun backFact(request:BackRequest,phase:Int):Boolean {
        check(sequence!=Long.MAX_VALUE) {"Leaf event sequence exhausted"}
        return AndroidViewsBridge.back(runtime.owner,activityMount,request.session,request.mount,
            request.handle,++sequence,request.revision,request.binding,request.request,
            request.router,request.history,request.current,request.previous,request.depth,phase)
    }

    private fun properties(view: View, op: Op) {
        view.isEnabled = op.enabled
        view.tag = op.id
        if (view is LeafEditText) view.hint = op.hint
        else if (view is TextView) view.text = op.label
        if(view is ProgressBar && op.kind==7) {
            view.max=10000
            view.progress=(op.progress*100).roundToInt()
        }
        // Each listener closes only over its opaque handle. Metadata is read
        // from the current binding; an old detached LeafView keeps its old epoch.
        if (op.kind == 3 && op.click) view.setOnClickListener {
            if (views[op.handle] !== view) return@setOnClickListener
            check(sequence != Long.MAX_VALUE) { "Leaf event sequence exhausted" }
            AndroidViewsBridge.event(runtime.owner, activityMount, session, eventMount,
                op.handle, ++sequence, observedRevision, 1, 0)
        } else {
            view.setOnClickListener(null)
            if (view !is LeafEditText && view !is CompoundButton) view.isClickable = false
        }
    }
    private fun create(op: Op): View {
        val view = when (op.kind) {
            0, 1, 12 -> FrameLayout(context)
            2 -> TextView(context)
            3 -> Button(context)
            4 -> LeafEditText(context) { view, kind, phase -> inputFact(op.handle, view, kind, phase) }
            5 -> LeafCheckBox(context) { view,binding,value -> checkedFact(op.handle,view,binding,value) }
            6 -> LeafSwitch(context) { view,binding,value -> checkedFact(op.handle,view,binding,value) }
            7 -> ProgressBar(context,null,android.R.attr.progressBarStyleHorizontal).apply { isIndeterminate=false }
            8 -> TextView(context)
            9 -> View(context).apply {
                val a=context.obtainStyledAttributes(intArrayOf(android.R.attr.listDivider))
                try { background=a.getDrawable(0) } finally { a.recycle() }
            }
            10 -> ProgressBar(context).apply { isIndeterminate=true }
            11 -> LeafRecyclerView(context) {view,offset -> scrollFact(op.handle,view,offset)}
            else -> error("Leaf Android kind is not implemented: ${op.kind}")
        }
        properties(view, op)
        view.onFocusChangeListener = OnFocusChangeListener { _, _ -> protectionFact(op.handle,view) }
        return view
    }

    fun measureNative(bytes: ByteArray, width: Double, height: Double): DoubleArray {
        require(width.isFinite() && height.isFinite() && width >= 0 && height >= 0)
        val op = parse(bytes).ops.single()
        val view = create(op) // Detached themed prototype; never a visible setter.
        if (view is LeafEditText) view.install(1) { view.write(op.value, 0, 0, false) }
        if(view is LeafCheckedControl) view.checkedBinding.install(1) { view.checkedBinding.write(op.checked) }
        val max = 0x3fffffff
        val w = (width * density).coerceIn(0.0, max.toDouble()).roundToInt()
        val h = (height * density).coerceIn(0.0, max.toDouble()).roundToInt()
        view.measure(MeasureSpec.makeMeasureSpec(w, MeasureSpec.AT_MOST),
                     MeasureSpec.makeMeasureSpec(h, MeasureSpec.AT_MOST))
        return doubleArrayOf(view.measuredWidth / density, view.measuredHeight / density)
    }

    fun stageNative(bytes: ByteArray) {
        val frame = parse(bytes)
        val next = LinkedHashMap(specs)
        val created = linkedMapOf<Long, View>()
        for (op in frame.ops) when (op.tag) {
            0 -> {
                check(op.handle !in next)
                next[op.handle] = op
                created[op.handle] = create(op)
            }
            1 -> { check(op.handle in next); next[op.handle] = next.getValue(op.handle).copy(
                enabled = op.enabled, click = op.click, label = op.label, value = op.value, hint = op.hint,
                checked=op.checked,progress=op.progress,list=op.list,row=op.row,back=op.back,navigation=op.navigation) }
            2 -> { check(op.handle in next); next[op.handle] = next.getValue(op.handle).copy(
                parent = op.parent, index = op.index,row=op.row) }
            3 -> { check(next.remove(op.handle) != null) }
        }
        check(next.size <= 10000)
        for (op in next.values) {
            val parent = next[op.parent]
            check(op.parent == 0L || (parent != null && (parent.kind in 0..1 || parent.kind in 11..12)))
            check((op.kind==11)==(op.list!=null))
            check((op.kind==12)==(op.navigation!=null) && (!op.back || op.kind==12))
            if(op.kind==12)check(next.values.count {it.parent==op.handle}==1)
            if(parent?.kind==11) {
                val row=checkNotNull(op.row);val meta=checkNotNull(parent.list)
                check(row.list==op.parent && row.source==meta.source && row.index in 0 until meta.count)
            } else check(op.row==null)
        }
        for(group in next.values.filter {it.row!=null}.groupBy {it.parent}.values) {
            check(group.map {it.row!!.index}.toSet().size==group.size)
            check(group.map {it.row!!.key}.toSet().size==group.size)
        }
        check(frame.lists.map {it.handle}.toSet()==next.values.filter {it.kind==11}.map {it.handle}.toSet())
        check(frame.lists.map {it.handle}.toSet().size==frame.lists.size)
        for(p in frame.lists) {
            val meta=checkNotNull(next.getValue(p.handle).list)
            check(p.source==meta.source && p.finish<=meta.count && p.protected.all {it<meta.count})
        }
        check(frame.boxes.map { it.handle }.toSet() == next.keys)
        check(frame.boxes.size == next.size)
        val intents=next.values.filter {it.kind==11}.associate {op ->
            op.handle to ((views[op.handle] ?: created[op.handle]) as LeafRecyclerView).intentSerial}
        attemptIntents=intents
        prepared = Plan(frame, next, created,intents)
    }

    open fun applyNative() {
        val p = checkNotNull(prepared)
        for (op in p.frame.ops) when (op.tag) {
            0 -> views[op.handle] = p.created.getValue(op.handle)
            1 -> properties(views.getValue(op.handle), p.specs.getValue(op.handle))
            2 -> Unit
            3 -> views.remove(op.handle)?.let { (it.parent as? ViewGroup)?.removeView(it) }
        }
        for (op in p.specs.values) {
            val view = views.getValue(op.handle)
            // Direct row roots belong to RecyclerView's physical holders.
            // Binding a holder only moves an already-built native subtree.
            if(op.row!=null)continue
            val parent = if (op.parent == 0L) this else views.getValue(op.parent) as ViewGroup
            if (view.parent !== parent) {
                (view.parent as? ViewGroup)?.removeView(view)
                parent.addView(view)
            }
        }
        // Ordering is metadata; layout is absolute DIP geometry. Avoid detaching
        // unchanged controls, which would lose focus/selection in later adapters.
        for (op in p.specs.values.sortedBy { it.index }) views.getValue(op.handle).bringToFront()
        layoutGeometry(p.frame,p.specs,p.intents)
        for (write in p.frame.writes) install(write)
        specs = p.specs
        observedRevision = p.frame.revision
        requestLayout()
    }
    private fun px(value:Double):Int=(value*density).coerceIn(-1_048_576.0,1_048_576.0).roundToInt()
    private fun layoutGeometry(frame:Frame,next:Map<Long,Op>,intents:Map<Long,Long>) {
        val boxes=frame.boxes.associateBy {it.handle}
        val protectedIndexes=frame.lists.associate {it.handle to it.protected.toSet()}
        val protectedRoots=next.values.filter {op ->
            op.row?.let {it.index in (protectedIndexes[it.list] ?: emptySet())} ?: false
        }.map {it.handle}.toSet()
        fun protectedSubtree(handle:Long):Boolean {
            var ancestor=handle
            var depth=0
            while(ancestor!=0L && depth++<64) {
                if(ancestor in protectedRoots)return true
                ancestor=next[ancestor]?.parent ?: return false
            }
            return false
        }
        for(box in frame.boxes) {
            val op=next.getValue(box.handle)
            val view = views.getValue(box.handle)
            val r = box.values
            val parent = boxes[op.parent]?.values
            val left = if(op.row!=null)0 else px(r[0] - (parent?.get(0) ?: 0.0))
            val top = if(op.row!=null)0 else px(r[1] - (parent?.get(1) ?: 0.0))
            val right = if(op.row!=null)px(r[2]) else px(r[0] + r[2] - (parent?.get(0) ?: 0.0))
            val bottom = if(op.row!=null)px(r[3]) else px(r[1] + r[3] - (parent?.get(1) ?: 0.0))
            view.layoutParams = LayoutParams((right-left).coerceAtLeast(0), (bottom-top).coerceAtLeast(0)).apply {
                leftMargin = left; topMargin = top
            }
            view.clipBounds = Rect(px(r[4]-r[0]), px(r[5]-r[1]),
                px(r[4]+r[6]-r[0]), px(r[5]+r[7]-r[1]))
            // INVISIBLE clears Android focus. Keep a protected subtree visible
            // with its empty clip/offscreen row box so the actual editor and
            // InputConnection retain focus/spans without drawing outside it.
            view.visibility = if ((r[6] > 0 && r[7] > 0) || protectedSubtree(box.handle)) VISIBLE else INVISIBLE
        }
        for(p in frame.lists) {
            val meta=checkNotNull(next.getValue(p.handle).list)
            val list=views.getValue(p.handle) as LeafRecyclerView
            val origin=boxes.getValue(p.handle).values
            val rows=next.values.filter {it.row?.list==p.handle}.sortedBy {it.row!!.index}.map {op ->
                val r=boxes.getValue(op.handle).values
                // A far-away retained row cannot overflow a native coordinate.
                val rect=if(r[6]<=0 || r[7]<=0)Rect(0,-65536,1,-65535) else Rect(
                    px(r[0]-origin[0]),px(r[1]-origin[1]),px(r[0]+r[2]-origin[0]),px(r[1]+r[3]-origin[1]))
                LeafRecyclerView.Row(op.handle,op.row!!.index,views.getValue(op.handle),rect,
                    op.row.index in p.protected)
            }
            list.install(p.source,meta.count,p.offset,p.total,p.height,rows,intents[p.handle] ?: list.intentSerial)
        }
    }
    fun discardNative() { prepared = null }
    fun replayNative(bytes: ByteArray) {
        disposeNative()
        stageNative(bytes)
        applyNative()
    }
    fun geometryNative(bytes:ByteArray) {
        val f=parse(bytes)
        check(f.ops.isEmpty() && f.writes.isEmpty())
        check(f.session==session && f.mount==eventMount && f.revision==observedRevision)
        check(f.boxes.map {it.handle}.toSet()==specs.keys && f.boxes.size==specs.size)
        layoutGeometry(f,specs,attemptIntents)
        requestLayout()
    }
    fun bindNative(bytes: ByteArray) {
        val f = parse(bytes)
        session = f.session; eventMount = f.mount; sequence = 0
        protection.clear()
    }
    private fun protectionFact(handle:Long,view:View) {
        if(!editorsActive || activityMount==0L || views[handle]!==view)return
        // Only typed row descendants participate. Nim validates the complete
        // accepted ancestor identities, including every enclosing list.
        var ancestor=handle
        var inRow=false
        var depth=0
        while(ancestor!=0L && depth++<64) {
            val op=specs[ancestor] ?: return
            if(op.row!=null) {inRow=true;break}
            ancestor=op.parent
        }
        if(!inRow)return
        val binding=when(view) {
            is LeafEditText -> view.binding
            is LeafCheckedControl -> view.checkedBinding.generation
            else -> 1L
        }
        val reasons=if(view is LeafEditText)view.protectionReasons() else if(view.isFocused)1 else 0
        val fact=Protection(binding,reasons)
        if(protection[handle]==fact || (protection[handle]==null && reasons==0))return
        check(sequence!=Long.MAX_VALUE) {"Leaf event sequence exhausted"}
        if(AndroidViewsBridge.protect(runtime.owner,activityMount,session,eventMount,handle,
            ++sequence,observedRevision,binding,reasons))protection[handle]=fact
    }
    /** JNI samples actual focus/spans before safeTurn can consume queued row
     * requests. Paused and stale Activity calls cannot update the receipt. */
    fun collectProtectionNative(mount:Long) {
        if(!editorsActive || mount!=activityMount)return
        protection.keys.retainAll(views.keys)
        for((handle,view) in views)protectionFact(handle,view)
    }
    private fun inputFact(handle: Long, view: LeafEditText, kind: Int, phase: Int): Boolean {
        if (views[handle] !== view || activityMount == 0L) return false
        protectionFact(handle,view)
        val text = view.text.toString()
        if (text.length > 1048576) return false
        val bytes = try { NativeBridge.encodeUtf8(text) } catch (_: CharacterCodingException) { return false }
        if (bytes.size > 1048576) return false
        check(sequence != Long.MAX_VALUE) { "Leaf event sequence exhausted" }
        return AndroidViewsBridge.input(runtime.owner, activityMount, session, eventMount, handle,
            ++sequence, observedRevision, view.binding, kind, bytes, phase,
            view.selectionStart.coerceAtLeast(0), view.selectionEnd.coerceAtLeast(0))
    }
    private fun checkedFact(handle:Long,view:CompoundButton,binding:Long,value:Boolean):Boolean {
        if(views[handle]!==view || activityMount==0L) return false
        check(sequence!=Long.MAX_VALUE) { "Leaf event sequence exhausted" }
        return AndroidViewsBridge.checked(runtime.owner,activityMount,session,eventMount,handle,
            ++sequence,observedRevision,binding,value)
    }
    private fun scrollFact(handle:Long,view:LeafRecyclerView,offset:Double):Boolean {
        if(views[handle]!==view || activityMount==0L)return false
        val source=specs[handle]?.list?.source ?: return false
        check(sequence!=Long.MAX_VALUE) {"Leaf event sequence exhausted"}
        return AndroidViewsBridge.scroll(runtime.owner,activityMount,session,eventMount,handle,
            ++sequence,observedRevision,source,offset)
    }
    private fun install(write: Write) {
        val view = views.getValue(write.handle)
        if(view is LeafCheckedControl) {
            view.checkedBinding.install(write.binding) {
                for(effect in write.effects) {
                    check(effect.kind==2) { "Unsupported Android checked effect" }
                    view.checkedBinding.write(effect.checked)
                }
            }
            view.checkedBinding.active(editorsActive)
        } else {
            check(view is LeafEditText)
            view.install(write.binding) {
            for (effect in write.effects) when (effect.kind) {
                0 -> view.cancelComposition()
                1 -> view.write(effect.value, effect.anchor, effect.caret, effect.force)
                3 -> view.select(effect.anchor, effect.caret)
                else -> error("Unsupported Android input effect")
            }
            }
            view.active(editorsActive)
        }
    }
    open fun editNative(bytes: ByteArray) {
        val f = parse(bytes)
        check(f.ops.isEmpty() && f.boxes.isEmpty())
        f.writes.forEach { install(it) }
    }
    fun selectionNative(bytes: ByteArray): DoubleArray {
        val view = views.getValue(parse(bytes).ops.single().handle) as LeafEditText
        return doubleArrayOf(view.selectionStart.coerceAtLeast(0).toDouble(),
            view.selectionEnd.coerceAtLeast(0).toDouble())
    }
    fun editorsActiveNative(value: Boolean) {
        editorsActive = value
        views.values.filterIsInstance<LeafEditText>().forEach { it.active(value) }
        views.values.filterIsInstance<LeafCheckedControl>().forEach { it.checkedBinding.active(value) }
    }
    open fun disposeNative() {
        views.values.filterIsInstance<LeafRecyclerView>().forEach {it.reset()}
        removeAllViews()
        views.clear(); specs.clear(); prepared = null
        protection.clear()
        attemptIntents=emptyMap()
    }
}
