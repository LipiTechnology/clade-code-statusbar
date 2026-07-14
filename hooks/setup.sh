#!/usr/bin/env bash
# SessionStart hook: make the plugin's status bar actually work.
#
# Plugins cannot declare a statusLine, and statusLine commands don't expand
# ${CLAUDE_PLUGIN_ROOT}. So we copy the script to the stable plugin data dir
# (survives updates, unlike the versioned cache path) and write that literal
# absolute path into the user's settings.json — but only if they don't already
# have a statusLine, so a user's own choice is never clobbered.
#
# Must never fail a session start: every step degrades quietly.

root="${CLAUDE_PLUGIN_ROOT:-}"
[ -n "$root" ] && [ -f "$root/statusline-command.sh" ] || exit 0

# ponytail: data dir is stable across updates; fall back to plugin root if the
# runtime is too old to set CLAUDE_PLUGIN_DATA (works until the next update).
data="${CLAUDE_PLUGIN_DATA:-$root}"
mkdir -p "$data" 2>/dev/null || data="$root"
cp "$root/statusline-command.sh" "$data/statusline-command.sh" 2>/dev/null || data="$root"
chmod +x "$data/statusline-command.sh" 2>/dev/null || true

settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
# Pin CLAUDE_CONFIG_DIR into the command so the script reads the right account
# file / cache dir even if it isn't inherited into the statusLine subprocess.
# Only when a custom dir is in use — default installs stay a plain command.
if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
  cmd="CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\" bash \"$data/statusline-command.sh\""
else
  cmd="bash \"$data/statusline-command.sh\""
fi

# Set statusLine only if absent. Prefer python3 (already a script dependency),
# fall back to jq; if neither exists, tell the user the one line to add.
script="$data/statusline-command.sh"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$settings" "$cmd" "$script" <<'PY' 2>/dev/null || true
import json, os, sys
path, cmd, script = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        data = {}
except Exception:
    data = {}
sl = data.get("statusLine")
# Create if absent; else rewrite only a statusLine that is OURS -- identified by
# it pointing at our script path -- so we can upgrade an older/unpinned command
# to the current one (pinned config dir + refreshInterval) without ever
# clobbering a status line the user set up themselves.
if not isinstance(sl, dict):
    data["statusLine"] = {"type": "command", "command": cmd, "refreshInterval": 1}
elif isinstance(sl.get("command"), str) and script in sl["command"] and (sl.get("command") != cmd or sl.get("refreshInterval") != 1):
    sl["command"] = cmd
    sl["refreshInterval"] = 1
else:
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
PY
elif command -v jq >/dev/null 2>&1 && [ -f "$settings" ]; then
  tmp="$(mktemp)" && jq --arg c "$cmd" --arg s "$script" 'if (.statusLine|type)!="object" then .statusLine={type:"command",command:$c,refreshInterval:1} elif (.statusLine.command|type)=="string" and (.statusLine.command|contains($s)) then .statusLine.command=$c | .statusLine.refreshInterval=1 else . end' "$settings" >"$tmp" 2>/dev/null && mv "$tmp" "$settings"
fi

exit 0
