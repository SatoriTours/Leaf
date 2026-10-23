package dev.leaf.runtime

import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.view.KeyEvent
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import android.view.inputmethod.InputConnectionWrapper
import android.view.inputmethod.InputMethodManager
import android.widget.EditText

/** Native editing facts only. Controlled values and composition conflicts are
 * decided by Nim's shared native_edit state machine, never by this View. */
internal class LeafEditText(context: Context,
    private val observe: (LeafEditText, Int, Int) -> Boolean) : EditText(context) {
    var binding = 1L
        private set
    private var setterDepth = 0
    private var connectionDepth = 0
    private var batchDepth = 0
    private var batchPhase: Int? = null
    private var active = false
    private var dirty = false
    private var lastPhase = 0
    private fun composing(): Boolean = BaseInputConnection.getComposingSpanStart(text) >= 0
    internal fun protectionReasons(): Int =
        (if (isFocused) 1 else 0) or (if (composing()) 2 else 0)
    private fun phase(): Int = if (composing()) {
        if (lastPhase == 0 || lastPhase == 4) 1 else 2
    } else if (lastPhase in 1..3) 4 else 0

    init {
        setSingleLine(true)
        imeOptions = EditorInfo.IME_ACTION_DONE
        addTextChangedListener(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable?) {
                if (setterDepth == 0 && connectionDepth == 0) emit()
            }
        })
        setOnEditorActionListener { _, action, key ->
            if (action == EditorInfo.IME_ACTION_DONE ||
                (key?.keyCode == KeyEvent.KEYCODE_ENTER && key.action == KeyEvent.ACTION_UP)) {
                emit(2); true
            } else false
        }
    }
    private fun emit(kind: Int = 1, requestedPhase: Int? = null) {
        if (setterDepth != 0) return
        if (batchDepth > 0) { dirty = true; batchPhase = requestedPhase; return }
        if (!active) { dirty = true; return }
        val current = requestedPhase ?: phase()
        if (observe(this, kind, current)) {
            lastPhase = current
            dirty = false
        } else dirty = true
    }
    fun active(value: Boolean) {
        active = value
        // finishComposingText can arrive after onPause without changing text.
        // Re-read the actual spans/selection before the first resumed UI turn.
        if (value && (dirty || (lastPhase in 1..3 && !composing()))) emit()
    }
    fun install(generation: Long, effects: () -> Unit) {
        binding = generation
        setterDepth++
        try { effects() } finally { setterDepth-- }
    }
    fun cancelComposition() {
        BaseInputConnection.removeComposingSpans(text)
        lastPhase = 0; dirty = false; batchPhase = null; batchDepth = 0
        if (isFocused) (context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager)
            .restartInput(this)
    }
    fun write(value: String, anchor: Int, caret: Int, force: Boolean) {
        if (force || text.toString() != value) {
            setText(value)
            select(anchor, caret)
        }
    }
    fun select(anchor: Int, caret: Int) {
        fun boundary(value: Int): Int {
            var p = value.coerceIn(0, text.length)
            if (p > 0 && p < text.length && Character.isLowSurrogate(text[p]) &&
                Character.isHighSurrogate(text[p - 1])) p--
            return p
        }
        setSelection(boundary(anchor), boundary(caret))
    }
    override fun onCreateInputConnection(info: EditorInfo): InputConnection? {
        val delegate = super.onCreateInputConnection(info) ?: return null
        return when {
            android.os.Build.VERSION.SDK_INT >= 34 -> Connection34(delegate)
            android.os.Build.VERSION.SDK_INT >= 33 -> Connection33(delegate)
            else -> Connection(delegate)
        }
    }
    private open inner class Connection(delegate: InputConnection) : InputConnectionWrapper(delegate, false) {
        private val generation = binding
        protected fun fact(requested: Int? = null, notify: Boolean = true, body: () -> Boolean): Boolean {
            if (generation != binding) return false
            connectionDepth++
            val answer: Boolean
            try { answer = body() } finally { connectionDepth-- }
            if (answer && notify) emit(requestedPhase = requested)
            return answer
        }
        protected fun commitFact(body: () -> Boolean): Boolean {
            val wasComposing = composing()
            val answer = fact(if (wasComposing) 3 else null, body = body)
            if (answer && wasComposing && !composing()) emit(requestedPhase = 4)
            return answer
        }
        override fun setComposingText(value: CharSequence?, cursor: Int): Boolean =
            fact { super.setComposingText(value, cursor) }
        override fun setComposingRegion(start: Int, end: Int): Boolean =
            fact { super.setComposingRegion(start, end) }
        override fun finishComposingText(): Boolean =
            fact(4, composing() || lastPhase in 1..3) { super.finishComposingText() }
        override fun commitText(value: CharSequence?, cursor: Int): Boolean =
            commitFact { super.commitText(value, cursor) }
        override fun commitCompletion(value: android.view.inputmethod.CompletionInfo?): Boolean =
            commitFact { super.commitCompletion(value) }
        override fun commitCorrection(value: android.view.inputmethod.CorrectionInfo?): Boolean =
            commitFact { super.commitCorrection(value) }
        override fun setSelection(start: Int, end: Int): Boolean =
            fact(notify = false) { super.setSelection(start, end) }
        override fun performEditorAction(action: Int): Boolean =
            fact(notify = false) { super.performEditorAction(action) }
        override fun performContextMenuAction(action: Int): Boolean =
            fact { super.performContextMenuAction(action) }
        override fun closeConnection() {
            fact(4, composing() || lastPhase in 1..3) { super.closeConnection(); true }
        }
        override fun deleteSurroundingText(before: Int, after: Int): Boolean =
            fact { super.deleteSurroundingText(before, after) }
        override fun deleteSurroundingTextInCodePoints(before: Int, after: Int): Boolean =
            fact { super.deleteSurroundingTextInCodePoints(before, after) }
        override fun sendKeyEvent(event: KeyEvent): Boolean = fact { super.sendKeyEvent(event) }
        override fun beginBatchEdit(): Boolean {
            var answer = false
            fact(notify = false) { answer = super.beginBatchEdit(); answer }
            if (answer) batchDepth++
            return answer
        }
        override fun endBatchEdit(): Boolean {
            var valid = false
            val answer = fact(notify = false) { valid = true; super.endBatchEdit() }
            if (!valid) return false
            if (batchDepth > 0) batchDepth--
            if (batchDepth == 0 && dirty) {
                val p = batchPhase; batchPhase = null
                emit(requestedPhase = p)
            }
            return answer
        }
    }
    // Keep newer framework types inside SDK-gated classes. The API26 adapter
    // does not load these classes, and all entry points share the same guard.
    @android.annotation.TargetApi(33)
    private open inner class Connection33(delegate: InputConnection) : Connection(delegate) {
        override fun setComposingText(value: CharSequence, cursor: Int,
            attributes: android.view.inputmethod.TextAttribute?): Boolean =
            fact { super.setComposingText(value, cursor, attributes) }
        override fun setComposingRegion(start: Int, end: Int,
            attributes: android.view.inputmethod.TextAttribute?): Boolean =
            fact { super.setComposingRegion(start, end, attributes) }
        override fun commitText(value: CharSequence, cursor: Int,
            attributes: android.view.inputmethod.TextAttribute?): Boolean =
            commitFact { super.commitText(value, cursor, attributes) }
    }
    @android.annotation.TargetApi(34)
    private inner class Connection34(delegate: InputConnection) : Connection33(delegate) {
        override fun replaceText(start: Int, end: Int, value: CharSequence, cursor: Int,
            attributes: android.view.inputmethod.TextAttribute?): Boolean =
            commitFact { super.replaceText(start, end, value, cursor, attributes) }
    }
}
