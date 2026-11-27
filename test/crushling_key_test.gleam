import crushling/key
import gleam/string

pub fn key_sanitizes_test() {
  let assert "T1-C0123-1699999999.000100" =
    key.to_string(key.new("T1", "C0123", "1699999999.000100"))
  let assert "T_x-a_b_c-d_e" = key.to_string(key.new("T/x", "a/b c", "d;e"))
  let assert 64 =
    string.length(key.to_string(key.new("T1", string.repeat("x", 100), "1")))
}

pub fn key_carries_the_team_test() {
  // Real ids: an 11-character workspace and channel, and a message ts.
  let thread = key.new("T0A1B2C3D4E", "C07QWERTY12", "1731888000.123456")
  let text = key.to_string(thread)
  let assert "T0A1B2C3D4E-C07QWERTY12-1731888000.123456" = text
  let assert True = string.length(text) <= 64
  let assert Ok(parsed) = key.parse(text)
  let assert "T0A1B2C3D4E" = key.team(parsed)
  let assert "C07QWERTY12" = key.channel(parsed)
  let assert "1731888000.123456" = key.ts(parsed)
  let assert True = parsed == thread
  // Enterprise Grid ids are longer, and still fit.
  let grid =
    key.to_string(key.new("E0123456789AB", "C0123456789AB", "1731888000.123456"))
  let assert True = string.length(grid) <= 64
  let assert False = string.contains(grid, "_")
  let assert Error(Nil) = key.parse("")
  // A key from before keys carried the workspace has none.
  let assert Error(Nil) = key.parse("C07QWERTY12-1731888000.123456")
  let assert Error(Nil) = key.parse("T-C1-1.0")
  let assert Error(Nil) = key.parse("T1-C1")
  let assert Error(Nil) = key.parse("T1-C1/x-1.0")
  let assert Ok(org) = key.parse("E0123-C1-1.0")
  let assert "E0123" = key.team(org)
}

pub fn is_valid_test() {
  let assert True = key.is_valid("k")
  let assert True = key.is_valid("T1-C1-1.0")
  let assert False = key.is_valid("")
  let assert False = key.is_valid(".")
  let assert False = key.is_valid("..")
  let assert False = key.is_valid("a/b")
  let assert False = key.is_valid("a b")
  let assert False = key.is_valid(string.repeat("x", 65))
}
