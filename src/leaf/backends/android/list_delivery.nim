## UI-thread glue for the owning Android adapter/session. Only records facts;
## MobileHost.safeTurn remains responsible for lifecycle-gated row building.
## Call after geometry projection. The ABI must validate its owner before
## supplying the adapter's session; this is not an external identity boundary.
import ../../backend_session
import ./list_layout

proc queueListViewports*(lists:AndroidLists,session:BackendSession):int =
  if session==nil:return 0
  for fact in lists.pendingListViewports():
    if session.queueRows(RowViewportRequest(sessionId:session.sessionId,
        mountGeneration:session.mountGeneration,listHandle:fact.handle,
        sourceGeneration:fact.sourceGeneration,first:fact.first,finish:fact.finish,
        protected:fact.protected)):
      # A refused queue insertion remains observable on the next ordinary
      # turn. An accepted fact is acknowledged even if its later row build
      # fails, so an idle frame cannot automatically retry the same failure.
      discard lists.markListViewportQueued(fact.handle,fact.token)
      inc result
