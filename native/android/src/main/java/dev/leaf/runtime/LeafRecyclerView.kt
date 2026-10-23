package dev.leaf.runtime

import android.content.Context
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.roundToInt

/** Physical accepted row slots only. The Runtime builds row subtrees on an
 * ordinary turn; bind/layout never calls it and never maintains a height index. */
internal class LeafRecyclerView(context:Context,private val fact:(LeafRecyclerView,Double)->Boolean):RecyclerView(context) {
    data class Row(val handle:Long,val index:Int,val view:View,val rect:Rect,val protected:Boolean=false)
    private class Holder(val root:FrameLayout):ViewHolder(root)
    private var rows=emptyList<Row>()
    private var source=0L
    private var count=0
    private var acceptedOffset=0.0
    private var desiredOffset=0.0
    private var total=0.0
    private var viewport=0.0
    var intentSerial=0L
        private set
    private val scale get()=resources.displayMetrics.density.toDouble()
    private val rowAdapter=object:Adapter<Holder>() {
        init {setHasStableIds(true)}
        override fun getItemCount()=rows.size
        override fun getItemId(position:Int)=rows[position].handle
        override fun onCreateViewHolder(parent:ViewGroup,viewType:Int)=Holder(FrameLayout(context))
        override fun onBindViewHolder(holder:Holder,position:Int) {
            val view=rows[position].view
            if(view.parent!==holder.root) {
                (view.parent as? ViewGroup)?.removeView(view)
                holder.root.removeAllViews()
                holder.root.addView(view)
            }
        }
        override fun onViewRecycled(holder:Holder) {holder.root.removeAllViews()}
    }
    private val projection=object:LayoutManager() {
        override fun generateDefaultLayoutParams()=LayoutParams(LayoutParams.MATCH_PARENT,LayoutParams.WRAP_CONTENT)
        override fun canScrollVertically()=total>viewport
        override fun requestChildRectangleOnScreen(parent:RecyclerView,child:View,rect:Rect,
            immediate:Boolean,focusedChildVisible:Boolean):Boolean {
            val row=rows.firstOrNull {it.view.parent===child}
            // A deliberately retained offscreen editor must not turn Android's
            // focus-reveal request into a new scroll intent after projection.
            if(row!=null && row.protected &&
                (row.rect.bottom<=0 || row.rect.top>=height))return false
            return super.requestChildRectangleOnScreen(parent,child,rect,immediate,focusedChildVisible)
        }
        override fun onLayoutChildren(recycler:Recycler,state:State) {
            detachAndScrapAttachedViews(recycler)
            if(state.isPreLayout)return
            for(index in rows.indices) {
                val child=recycler.getViewForPosition(index)
                addView(child)
                val rect=rows[index].rect
                child.measure(View.MeasureSpec.makeMeasureSpec(rect.width(),View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(rect.height(),View.MeasureSpec.EXACTLY))
                layoutDecorated(child,rect.left,rect.top,rect.right,rect.bottom)
            }
        }
        override fun scrollVerticallyBy(dy:Int,recycler:Recycler,state:State):Int {
            if(dy==0 || source==0L)return 0
            val next=(desiredOffset+dy/scale).coerceIn(0.0,(total-viewport).coerceAtLeast(0.0))
            val consumed=((next-desiredOffset)*scale).roundToInt()
            if(consumed==0 || !fact(this@LeafRecyclerView,next))return 0
            check(intentSerial!=Long.MAX_VALUE) {"Leaf scroll intent exhausted"}
            intentSerial++
            desiredOffset=next
            return consumed // The next ordinary turn projects accepted boxes.
        }
        private fun metric(value:Double):Int {
            if(total<=0)return 0
            // Ratios preserve huge logical extents without pixel/int overflow.
            return (value/total*1_000_000).coerceIn(0.0,1_000_000.0).roundToInt()
        }
        override fun computeVerticalScrollRange(state:State)=if(total>0)1_000_000 else 0
        override fun computeVerticalScrollExtent(state:State)=metric(viewport.coerceAtMost(total))
        override fun computeVerticalScrollOffset(state:State)=metric(acceptedOffset)
        override fun getRowCountForAccessibility(recycler:Recycler,state:State)=count
        override fun getColumnCountForAccessibility(recycler:Recycler,state:State)=1
        override fun onInitializeAccessibilityNodeInfoForItem(recycler:Recycler,state:State,host:View,
            info:AccessibilityNodeInfoCompat) {
            super.onInitializeAccessibilityNodeInfoForItem(recycler,state,host,info)
            val position=getPosition(host)
            if(position in rows.indices)info.setCollectionItemInfo(
                AccessibilityNodeInfoCompat.CollectionItemInfoCompat.obtain(rows[position].index,1,0,1,false,false))
        }
    }
    init {
        layoutManager=projection;adapter=rowAdapter;itemAnimator=null
        setItemViewCacheSize(0);recycledViewPool.setMaxRecycledViews(0,8)
        isVerticalScrollBarEnabled=true;clipToPadding=true
    }
    fun install(source:Long,count:Int,offset:Double,total:Double,viewport:Double,
                next:List<Row>,attemptSerial:Long) {
        check(!isComputingLayout) {"Leaf projection must run outside RecyclerView layout"}
        val changed=rows.size!=next.size || rows.indices.any {rows[it].handle!=next[it].handle || rows[it].view!==next[it].view}
        if(this.source!=source || intentSerial==attemptSerial)desiredOffset=offset
        this.source=source;this.count=count;acceptedOffset=offset;this.total=total;this.viewport=viewport
        rows=next
        if(changed)rowAdapter.notifyDataSetChanged() else requestLayout()
        invalidate()
    }
    fun reset() {
        stopScroll();rows=emptyList();rowAdapter.notifyDataSetChanged()
        source=0;count=0;total=0.0;viewport=0.0;acceptedOffset=0.0;desiredOffset=0.0
    }
}
