//// What inference cost and the limits on it, shared by the proxy that counts
//// it, the store that keeps it and the App Home that shows it.

import gleam/option.{type Option, None, Some}

/// What was spent: by one response, one thread, or the whole instance.
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, cost_usd: Float, requests: Int)
}

pub const zero = Usage(0, 0, 0.0, 0)

pub fn add(a: Usage, b: Usage) -> Usage {
  Usage(
    input_tokens: a.input_tokens + b.input_tokens,
    output_tokens: a.output_tokens + b.output_tokens,
    cost_usd: a.cost_usd +. b.cost_usd,
    requests: a.requests + b.requests,
  )
}

pub fn tokens(usage: Usage) -> Int {
  usage.input_tokens + usage.output_tokens
}

/// A spending limit. `None` in a field means no limit on that measure.
pub type Cap {
  Cap(tokens: Option(Int), usd: Option(Float))
}

pub const unlimited = Cap(None, None)

pub fn reached(usage: Usage, cap: Cap) -> Bool {
  let over_tokens = case cap.tokens {
    Some(limit) -> tokens(usage) >= limit
    None -> False
  }
  let over_usd = case cap.usd {
    Some(limit) -> usage.cost_usd >=. limit
    None -> False
  }
  over_tokens || over_usd
}
