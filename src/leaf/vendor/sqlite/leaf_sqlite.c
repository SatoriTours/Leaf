/* One app-private SQLite implementation for Leaf and its ORM bindings. */
#if defined(__GNUC__) || defined(__clang__)
#define SQLITE_API __attribute__((visibility("hidden")))
#endif
#define SQLITE_THREADSAFE 1
#define SQLITE_OMIT_LOAD_EXTENSION 1
#include "sqlite3.c"
