//// crushling: a Crush agent per Slack thread.
////
////     gleam run
////
//// Settings come from the environment or `./.env`; docs/configuration.md lists them.

import crushling/boot
import crushling/config
import gleam/io
import gleam/list

@external(erlang, "crushling_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

pub fn main() -> Nil {
  case config.parse(getenv) {
    Error(reasons) -> {
      list.each(reasons, fn(reason) {
        io.println_error("crushling: " <> reason)
      })
      halt(1)
    }
    Ok(config) ->
      case boot.run(config) {
        Ok(code) -> halt(code)
        Error(reason) -> {
          io.println_error("crushling: " <> reason)
          halt(1)
        }
      }
  }
}
