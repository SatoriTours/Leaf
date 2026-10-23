package dev.leaf.testbridge

import android.app.Activity
import android.os.Bundle
import android.os.Process
import android.util.Log
import android.view.WindowInsets
import android.widget.TextView
import dev.leaf.runtime.NativeBridge
import java.io.File
import java.nio.charset.CharacterCodingException

/** Executable integration fixture. Uses the product bridge, not a mock JNI. */
class MainActivity : Activity() {
    private external fun initializationMarker(): Int

    private inline fun <reified T : Throwable> rejects(block: () -> Unit) {
        try { block() } catch (error: Throwable) {
            check(error is T) { "Expected ${T::class.java.name}, got $error" }
            return
        }
        error("Expected ${T::class.java.name}")
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        System.loadLibrary("leaf_android_boundary")
        System.loadLibrary("leaf_android_boundary")
        val label = TextView(this).apply { text = "Checking native UTF-8 boundary" }
        label.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            view.setPadding(bars.left + 24, bars.top + 24, bars.right + 24, bars.bottom + 24)
            insets
        }
        setContentView(label)
        // Before initialization, even a main-thread copy must fail safely.
        rejects<IllegalStateException> { NativeBridge.copyUtf8(byteArrayOf()) }
        Thread {
            // Worker-first initialization must not enter Nim at all.
            rejects<IllegalStateException> { NativeBridge.initialize() }
            rejects<IllegalStateException> { NativeBridge.copyUtf8(byteArrayOf(65)) }
            runOnUiThread {
                NativeBridge.initialize()
                val first = initializationMarker()
                NativeBridge.initialize()
                val second = initializationMarker()
                check(first == 1001 && second == 1001) { "Repeated Nim initialization $first/$second" }
                val values = listOf("", "ASCII", "中文 / 日本語 / café", "A\u0000B", "😀𐐷🧪", "\u0000😀中文\u0000")
                values.forEach { value ->
                    val input = NativeBridge.encodeUtf8(value)
                    val output = NativeBridge.copyUtf8(input)
                    check(output !== input && output.contentEquals(input))
                    check(NativeBridge.decodeUtf8(output) == value)
                    check(initializationMarker() == first)
                }
                val invalid = listOf(
                    intArrayOf(0x80), intArrayOf(0xc0,0x80), intArrayOf(0xe0,0x9f,0x80),
                    intArrayOf(0xed,0xa0,0x80), intArrayOf(0xf0,0x8f,0xbf,0xbf),
                    intArrayOf(0xf4,0x90,0x80,0x80), intArrayOf(0xf0,0x9f,0x98)
                )
                invalid.forEach { bytes ->
                    rejects<IllegalArgumentException> { NativeBridge.copyUtf8(bytes.map { it.toByte() }.toByteArray()) }
                    // A JNI exception is consumed by Java, not left pending.
                    check(NativeBridge.decodeUtf8(NativeBridge.copyUtf8(byteArrayOf(65))) == "A")
                }
                rejects<CharacterCodingException> { NativeBridge.encodeUtf8("\ud800") }
                rejects<CharacterCodingException> { NativeBridge.encodeUtf8("\udfff") }
                val max = ByteArray(1048576) { if (it % 2 == 0) 0 else 65 }
                check(NativeBridge.copyUtf8(max).contentEquals(max))
                rejects<IllegalArgumentException> { NativeBridge.copyUtf8(ByteArray(1048577)) }
                repeat(4096) {
                    val value = values[it % values.size]
                    check(NativeBridge.decodeUtf8(NativeBridge.copyUtf8(NativeBridge.encodeUtf8(value))) == value)
                }
                Thread {
                    rejects<IllegalStateException> { NativeBridge.initialize() }
                    rejects<IllegalStateException> { NativeBridge.copyUtf8(byteArrayOf(65)) }
                    runOnUiThread {
                        check(initializationMarker() == 1001)
                        val result = "status=passed cases=6 invalid=7 lone_surrogates=2 stress=4096 max_bytes=1048576 worker_before=rejected worker_after=rejected init=1001/1001 main_tid=${Process.myTid()}"
                        File(filesDir, "boundary-result.txt").writeText(result + "\n")
                        label.text = "Leaf JNI boundary: passed\n中文 / 日本語 / café\n😀𐐷🧪\nNUL bytes retained\n" + result
                        Log.i("LeafBoundary", result)
                    }
                }.start()
            }
        }.start()
    }
}
