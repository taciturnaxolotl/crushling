//// The names of the environment variables a thread's crush is given, in one
//// place, so the bridge that sets them and the crush.json that reads them
//// can't drift apart.

/// The thread's key, for its Slack tools endpoint and the file helpers.
pub const thread = "CRUSHLING_THREAD"

/// The bearer token for the thread's Slack tools and files.
pub const mcp_token = "CRUSHLING_MCP_TOKEN"

/// How the sandbox reaches the bridge, for `crushling-fetch` and `-share`.
pub const bridge_url = "CRUSHLING_BRIDGE_URL"

/// The bearer token `crush server --dial` presents to the tunnel.
pub const dial_token = "CRUSH_SERVER_DIAL_TOKEN"

/// The bridge owns the lifecycle, so the server must not exit on its own.
pub const idle_timeout = "CRUSH_SERVER_IDLE_TIMEOUT"

pub const detach_grace = "CRUSH_SERVER_DETACH_GRACE"

/// The inference proxy, as crush's own names for Hyper.
pub const hyper_url = "HYPER_URL"

pub const hyper_api_key = "HYPER_API_KEY"

pub const home = "HOME"

pub const xdg_data_home = "XDG_DATA_HOME"

pub const xdg_cache_home = "XDG_CACHE_HOME"

pub const honcho_config_dir = "HONCHO_CONFIG_DIR"

pub const crush_global_config = "CRUSH_GLOBAL_CONFIG"

pub const crush_global_data = "CRUSH_GLOBAL_DATA"

/// A `NAME=value` pair.
pub fn pair(name: String, value: String) -> String {
  name <> "=" <> value
}
