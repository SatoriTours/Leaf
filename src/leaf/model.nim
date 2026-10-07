## Rails-style model declarations; importing this module never opens a database.
import std/[options, times]
import ./model/[record, context, errors, declarations]
export options, times, errors, declarations
export Record, TimestampedRecord, id, isNewRecord, isPersisted, isDestroyed
export withDatabase, currentDatabase
