//// Every module's tables, in the order they're made: a module's come after
//// those of any module they refer to.

import crushling/store.{type Migration, type Store}
import crushling/store/github as accounts
import crushling/store/legacy_import
import crushling/store/teams
import crushling/store/threads
import crushling/store/usage
import gleam/list

pub fn migrations() -> List(Migration) {
  list.flatten([
    teams.migrations(),
    threads.migrations(),
    legacy_import.migrations(),
    usage.migrations(),
    accounts.migrations(),
  ])
}

/// Open the store at `path` with every module's tables.
pub fn open(path: String, key: BitArray) -> Result(Store, String) {
  store.start(path, key, migrations())
}
