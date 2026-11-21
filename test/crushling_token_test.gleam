import crushling/token

pub fn tokens_are_per_purpose_test() {
  let mcp = token.mint("s", token.Mcp, "T1-C1-1.0")
  let tunnel = token.mint("s", token.Tunnel, "T1-C1-1.0")
  let proxy = token.mint("s", token.Proxy, "T1-C1-1.0")
  let assert True = mcp != tunnel && tunnel != proxy && mcp != proxy
  let assert True =
    token.authorized("s", token.Tunnel, "T1-C1-1.0", "Bearer " <> tunnel)
  let assert False =
    token.authorized("s", token.Proxy, "T1-C1-1.0", "Bearer " <> tunnel)
  let assert False =
    token.authorized("s", token.Tunnel, "T1-C1-2.0", "Bearer " <> tunnel)
  let assert False =
    token.authorized("other", token.Tunnel, "T1-C1-1.0", "Bearer " <> tunnel)
  let assert False =
    token.authorized("s", token.Tunnel, "", "Bearer " <> tunnel)
  let assert False = token.authorized("s", token.Tunnel, "T1-C1-1.0", tunnel)
}
