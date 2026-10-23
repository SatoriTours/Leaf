package dev.leaf.runtime

import java.nio.ByteBuffer
import java.nio.CharBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** The application loads its Nim library before initialize, on the main Looper.
 * JNI independently rejects foreign threads, including initialization attempts.
 * All strings cross JNI as explicit UTF-8 byte arrays, never Modified UTF-8.
 * No Activity/View or business closure is retained by this bridge. */
object NativeBridge {
    external fun initialize()
    external fun copyUtf8(input: ByteArray): ByteArray

    fun encodeUtf8(value: String): ByteArray {
        val encoder = StandardCharsets.UTF_8.newEncoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
        val bytes = encoder.encode(CharBuffer.wrap(value))
        return ByteArray(bytes.remaining()).also { bytes.get(it) }
    }

    fun decodeUtf8(value: ByteArray): String = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(value)).toString()
}
