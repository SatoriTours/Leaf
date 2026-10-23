package dev.leaf.runtime

/** Internal result preserves cleanup identities even when attach/startup fails.
 * Capture owner/mount before propagating failure. Never persist these IDs. */
class AndroidCall {
    @JvmField var owner = 0L
    @JvmField var mount = 0L
    @JvmField var status = 0
    @JvmField var failure: Throwable? = null
    fun requireSuccess() {
        failure?.let { throw it }
        check(status == 0) { "Leaf native operation failed: $status" }
    }
}

object AndroidViewsBridge {
    external fun createOwner(): AndroidCall
    external fun createOwnerWithResources(assets: android.content.res.AssetManager,
                                         dataDirectory: ByteArray, cacheDirectory: ByteArray): AndroidCall
    external fun attach(owner: Long, view: LeafView, width: Double, height: Double, scale: Double): AndroidCall
    external fun phase(owner: Long, mount: Long, phase: Int): Boolean
    external fun event(owner: Long, activityMount: Long, session: Long, eventMount: Long,
                       handle: Long, sequence: Long, revision: Long, binding: Long, kind: Int): Boolean
    external fun input(owner: Long, activityMount: Long, session: Long, eventMount: Long,
                       handle: Long, sequence: Long, revision: Long, binding: Long,
                       kind: Int, value: ByteArray, phase: Int, anchor: Int, caret: Int): Boolean
    external fun checked(owner: Long, activityMount: Long, session: Long, eventMount: Long,
                         handle: Long, sequence: Long, revision: Long, binding: Long, checked: Boolean): Boolean
    external fun scroll(owner: Long, activityMount: Long, session: Long, eventMount: Long,
                        handle: Long, sequence: Long, revision: Long, source: Long, offset: Double): Boolean
    external fun protect(owner: Long, activityMount: Long, session: Long, eventMount: Long,
                         handle: Long, sequence: Long, revision: Long, binding: Long, reasons: Int): Boolean
    external fun back(owner:Long,activityMount:Long,session:Long,eventMount:Long,handle:Long,
                      sequence:Long,revision:Long,binding:Long,request:Long,router:Long,
                      history:Long,current:Long,previous:Long,depth:Int,phase:Int):Boolean
    external fun close(owner: Long)
}
