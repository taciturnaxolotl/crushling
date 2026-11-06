# crush server API, condensed for the bridge

Source: ~/code/charm/crush at 67a5524fdf. Live spec: GET /v1/docs/openapi.json.

## Start
- `crush server -H unix:///run/crush.sock` (plus `-D <data-dir>`). No auth; socket perms only.
- Self-shuts down when idle: set `CRUSH_SERVER_IDLE_TIMEOUT` high (or rely on container lifecycle).
- Claims: open SSE within 30 s of workspace create; claim survives 10 s after stream drop
  (`CRUSH_SERVER_DETACH_GRACE`). Keep one SSE open per workspace, reconnect fast.
- No heartbeat on SSE: no read timeout. No replay on reconnect: re-read state.

## Sequence
```
POST /v1/workspaces {"path":"/workspace","client_id":"<uuid>","permission_mode":"yolo"} -> {"id":W}
GET  /v1/workspaces/W/events?client_id=<uuid>          (SSE, data-only lines)
POST /v1/workspaces/W/agent/init {"interactive":false}
GET  /v1/workspaces/W/agent  poll until is_ready (200 ms, 30 s)
POST /v1/workspaces/W/sessions {"title":"slack C/ts"} -> {"id":S}
POST /v1/workspaces/W/agent {"session_id":S,"run_id":R,"prompt":"..."} -> 202
SSE run_complete {session_id,run_id,message_id,text,error,cancelled} -> done
cancel: POST /v1/workspaces/W/agent/sessions/S/cancel
cleanup: DELETE /v1/clients/<uuid>
```

## Rules
- Always send a fresh `run_id`: with one, a follow-up while busy is its own turn with its own
  run_complete; without, it's folded into the active turn.
- Envelope: `{"type":<kind>,"payload":{"type":"created|updated|deleted","payload":{...}}}`.
- `message` updates carry the full accumulated text, debounced and lossy: diff `text` per message id.
- Never use `finish` parts as end of run. Use `run_complete` (must-deliver).
- `agent_event` type "error" = failure; an errored run_complete follows when run_id was set.
- Yolo suppresses permission_request entirely. Never call current-session (fail-open routing).
- Errors: `{"message":...}`. 200 often has an empty body.
- Diffs: no endpoint. Use `file` SSE events (snake_case) or `/sessions/S/history`
  (Go field names, capitalized!), or edit tool_result.metadata {old_content,new_content}.
- Model switch: POST /config/model {"scope":1,"model_type":"large","model":{...}} then POST /agent/update.
- One workspace per resolved path (dedup; first create's mode wins). One container per thread means
  one workspace per server, so this mostly doesn't bite.

## Unconfirmed
Parallel runs across sessions; sub-agent run_complete; validation errors probably 500 not 400;
summarize event shape.
