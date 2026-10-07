## Rails-style model declarations; importing this module never opens a database.
import std/[options, times]
import ./model/[record, context, errors, declarations, changes]
export options, times, errors, declarations, changes
export Record, TimestampedRecord, id, isNewRecord, isPersisted, isDestroyed
export withDatabase, currentDatabase
export errors, savedChanges
