package dev.leaf.runtime

import android.content.Context
import android.widget.CheckBox
import android.widget.CompoundButton
import android.widget.Switch

/** Per-native-control facts/guard. Never shared across sibling controls. */
internal class CheckedBinding(private val view:CompoundButton,
                              private val changed:(Long,Boolean)->Boolean) {
    var generation=0L
        private set
    private var setterDepth=0
    private var active=false
    private var dirty=false
    init {
        view.setOnCheckedChangeListener { _,value ->
            if(setterDepth==0) {
                if(active) changed(generation,value) else dirty=true
            }
        }
    }
    fun install(binding:Long,body:()->Unit) {
        require(binding>0)
        generation=binding
        setterDepth++
        try { body() } finally { setterDepth-- }
    }
    fun write(value:Boolean) {
        if(view.isChecked!=value) view.isChecked=value
    }
    fun active(value:Boolean) {
        val was=active
        active=value
        if(value && !was && dirty) {
            dirty=false
            changed(generation,view.isChecked)
        }
    }
}
internal interface LeafCheckedControl { val checkedBinding:CheckedBinding }
internal class LeafCheckBox(context:Context,fact:(CompoundButton,Long,Boolean)->Boolean)
    : CheckBox(context),LeafCheckedControl {
    override val checkedBinding=CheckedBinding(this) { binding,value -> fact(this,binding,value) }
}
@Suppress("DEPRECATION")
internal class LeafSwitch(context:Context,fact:(CompoundButton,Long,Boolean)->Boolean)
    : Switch(context),LeafCheckedControl {
    override val checkedBinding=CheckedBinding(this) { binding,value -> fact(this,binding,value) }
}
