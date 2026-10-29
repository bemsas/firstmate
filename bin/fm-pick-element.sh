#!/usr/bin/env bash
# fm-pick-element.sh - capture a clicked element from the current browser page
# and steer it to the worker that owns a task.
#
# Usage:
#   fm-pick-element.sh pick <task-id> [--comment <text>]
#   fm-pick-element.sh send <task-id> (--uid @<ref> | --selector <css>) [--comment <text>]
#
# The captain drives a visible app or Lavish sketch through chrome-devtools-axi
# (typically after eval "$(bin/fm-browser.sh start)" and opening the page).
# pick installs a one-shot overlay in the page and waits for one click.
# send captures a known snapshot ref or CSS selector without the overlay.
#
# Artifacts land under data/<task-id>/pick/<epoch>/ (dom.txt, screenshot.png,
# snapshot.txt when useful, manifest.json). Delivery uses bin/fm-send.sh so the
# worker reads the steer from its steering inbox.
#
# Environment: FM_HOME required (same rule as fm-send.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'fm-pick-element: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 2; }

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  die "FM_HOME is not set"
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

command -v chrome-devtools-axi >/dev/null 2>&1 \
  || die "chrome-devtools-axi is not installed"
command -v jq >/dev/null 2>&1 || die "jq is not installed"

task_meta_path() { # <task-id>
  printf '%s/%s.meta' "$STATE" "$1"
}

require_task() { # <task-id>
  local id=$1 meta
  meta=$(task_meta_path "$id")
  [ -f "$meta" ] || die "unknown task '$id' (missing $meta)"
}

artifact_dir_for() { # <task-id>
  local id=$1 base
  base="$DATA/$id/pick/$(date +%s)"
  mkdir -p "$base" || die "cannot create artifact directory: $base"
  printf '%s\n' "$base"
}

write_manifest() { # <dir> <task-id> <source> <json-capture>
  local dir=$1 task=$2 source=$3 json=$4 manifest
  manifest="$dir/manifest.json"
  printf '%s\n' "$json" | jq -c \
    --arg schema "fm-pick-element.v1" \
    --arg task "$task" \
    --arg source "$source" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '. + {schema: $schema, task: $task, source: $source, at: $at}' >"$manifest" \
    || die "cannot write manifest"
  cat "$manifest"
}

capture_interactive() {
  chrome-devtools-axi run 2>&1 <<'JS'
const data = await page.eval(() => new Promise((resolve) => {
  if (window.__fmPickActive) {
    resolve({ error: "picker already active" });
    return;
  }
  window.__fmPickActive = true;
  const banner = document.createElement("div");
  banner.textContent = "Firstmate: click an element to send feedback to the worker (Esc cancels)";
  banner.style.cssText = [
    "position:fixed", "top:0", "left:0", "right:0", "z-index:2147483647",
    "background:#111", "color:#fff", "padding:8px 12px", "font:14px system-ui",
    "text-align:center", "pointer-events:none"
  ].join(";");
  document.documentElement.appendChild(banner);
  const style = document.createElement("style");
  style.textContent = "[data-fm-pick-target]{outline:2px solid #ff4466!important;outline-offset:2px!important}";
  document.head.appendChild(style);
  let hover = null;
  function cssPath(el) {
    if (!el || el.nodeType !== 1) return "";
    const parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement) {
      let part = el.tagName.toLowerCase();
      if (el.id) {
        part += "#" + CSS.escape(el.id);
        parts.unshift(part);
        break;
      }
      const parent = el.parentElement;
      if (!parent) break;
      const siblings = [...parent.children].filter((c) => c.tagName === el.tagName);
      if (siblings.length > 1) {
        part += ":nth-of-type(" + (siblings.indexOf(el) + 1) + ")";
      }
      parts.unshift(part);
      el = parent;
    }
    return parts.join(" > ");
  }
  function cleanup() {
    document.removeEventListener("mousemove", onMove, true);
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("keydown", onKey, true);
    if (hover) hover.removeAttribute("data-fm-pick-target");
    banner.remove();
    style.remove();
    delete window.__fmPickActive;
  }
  function onMove(e) {
    if (banner.contains(e.target)) return;
    if (hover) hover.removeAttribute("data-fm-pick-target");
    hover = e.target;
    if (hover) hover.setAttribute("data-fm-pick-target", "");
  }
  function onKey(e) {
    if (e.key === "Escape") {
      cleanup();
      resolve({ cancelled: true });
    }
  }
  function onClick(e) {
    if (banner.contains(e.target)) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    const el = e.target;
    cleanup();
    resolve({
      cancelled: false,
      url: location.href,
      selector: cssPath(el),
      tag: el.tagName.toLowerCase(),
      text: (el.innerText || "").trim().slice(0, 500),
      outerHTML: el.outerHTML.slice(0, 8192),
      viewport: { width: innerWidth, height: innerHeight },
    });
  }
  document.addEventListener("mousemove", onMove, true);
  document.addEventListener("click", onClick, true);
  document.addEventListener("keydown", onKey, true);
}));
console.log(JSON.stringify(data));
JS
}

capture_selector() { # <css>
  local sel=$1
  chrome-devtools-axi run 2>&1 <<JS
const sel = $(jq -Rn --arg s "$sel" '$s');
const data = await page.eval((selector) => {
  const el = document.querySelector(selector);
  if (!el) return { error: "selector not found", selector };
  return {
    cancelled: false,
    url: location.href,
    selector,
    tag: el.tagName.toLowerCase(),
    text: (el.innerText || "").trim().slice(0, 500),
    outerHTML: el.outerHTML.slice(0, 8192),
    viewport: { width: innerWidth, height: innerHeight },
  };
}, sel);
console.log(JSON.stringify(data));
JS
}

parse_capture_json() { # <stdout>
  local raw=$1 line
  line=$(printf '%s\n' "$raw" | awk '/^\{.*\}$/ { line=$0 } END { print line }')
  [ -n "$line" ] || die "chrome-devtools-axi did not return element capture JSON"
  printf '%s' "$line"
}

save_capture() { # <dir> <json-line>
  local dir=$1 json=$2 dom_file shot_file snap_file uid selector
  dom_file="$dir/dom.txt"
  shot_file="$dir/screenshot.png"
  snap_file="$dir/snapshot.txt"
  if jq -e '.cancelled == true' >/dev/null 2>&1 <<<"$json"; then
    die "pick cancelled"
  fi
  if jq -e '.error' >/dev/null 2>&1 <<<"$json"; then
    die "$(jq -r '.error' <<<"$json")"
  fi
  jq -r '.outerHTML // ""' <<<"$json" >"$dom_file"
  chrome-devtools-axi snapshot >"$snap_file" 2>/dev/null || : >"$snap_file"
  uid=$(jq -r '.uid // empty' <<<"$json")
  selector=$(jq -r '.selector // empty' <<<"$json")
  if [ -n "$uid" ]; then
    chrome-devtools-axi screenshot "$shot_file" --uid "$uid" \
      || die "screenshot failed for uid $uid"
  else
    chrome-devtools-axi screenshot "$shot_file" \
      || die "screenshot failed"
  fi
  jq -n \
    --argjson cap "$json" \
    --arg dom "$dom_file" \
    --arg screenshot "$shot_file" \
    --arg snapshot "$snap_file" \
    '$cap + {paths: {dom: $dom, screenshot: $screenshot, snapshot: $snapshot}}'
}

deliver() { # <task-id> <artifact-dir> <manifest-json> <comment> <source>
  local task=$1 dir=$2 manifest=$3 comment=$4 source=$5 msg
  write_manifest "$dir" "$task" "$source" "$manifest" >/dev/null
  msg=$(jq -r \
    --arg comment "$comment" \
    --arg manifest "$dir/manifest.json" \
    '
      def opt_comment:
        if ($comment | length) > 0 then "\ncomment: " + $comment else "" end;
      "Captain element feedback (fm-pick-element.v1)\n" +
      "manifest: " + $manifest + "\n" +
      "page: " + (.url // "(unknown)") + "\n" +
      "selector: " + (.selector // "(unknown)") + "\n" +
      "tag: " + (.tag // "") + "\n" +
      "viewport: " + ((.viewport.width // "?")|tostring) + "x" + ((.viewport.height // "?")|tostring) + "\n" +
      "dom: " + (.paths.dom // "") + "\n" +
      "screenshot: " + (.paths.screenshot // "") + "\n" +
      "snapshot: " + (.paths.snapshot // "") + opt_comment +
      "\n\nRead the manifest, DOM excerpt, and screenshot paths above."
    ' <<<"$manifest")
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$task" "$msg"
}

cmd_pick() {
  local task='' comment=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --comment)
        [ "$#" -ge 2 ] || usage
        comment=$2
        shift 2
        ;;
      --*) usage ;;
      *)
        [ -z "$task" ] || usage
        task=$1
        shift
        ;;
    esac
  done
  [ -n "$task" ] || usage
  require_task "$task"
  local dir raw json enriched
  dir=$(artifact_dir_for "$task")
  raw=$(capture_interactive) || die "interactive capture failed"
  json=$(parse_capture_json "$raw")
  enriched=$(save_capture "$dir" "$json")
  deliver "$task" "$dir" "$enriched" "$comment" pick
  printf 'delivered: task=%s dir=%s\n' "$task" "$dir"
}

cmd_send() {
  local task='' uid='' selector='' comment=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --uid)
        [ "$#" -ge 2 ] || usage
        uid=$2
        shift 2
        ;;
      --selector)
        [ "$#" -ge 2 ] || usage
        selector=$2
        shift 2
        ;;
      --comment)
        [ "$#" -ge 2 ] || usage
        comment=$2
        shift 2
        ;;
      --*) usage ;;
      *)
        [ -z "$task" ] || usage
        task=$1
        shift
        ;;
    esac
  done
  [ -n "$task" ] || usage
  [ -n "$uid" ] || [ -n "$selector" ] || die "send requires --uid or --selector"
  require_task "$task"
  local dir raw json cap enriched
  dir=$(artifact_dir_for "$task")
  if [ -n "$selector" ]; then
    raw=$(capture_selector "$selector") || die "selector capture failed"
    json=$(parse_capture_json "$raw")
  else
    json=$(jq -n --arg uid "$uid" '{uid: $uid, outerHTML: "", url: "", tag: "", viewport: {}}')
  fi
  cap=$(printf '%s' "$json" | jq --arg uid "$uid" '. + (if ($uid|length)>0 then {uid:$uid} else {} end)')
  enriched=$(save_capture "$dir" "$cap")
  deliver "$task" "$dir" "$enriched" "$comment" send
  printf 'delivered: task=%s dir=%s\n' "$task" "$dir"
}

case "${1-}" in
  pick) shift; cmd_pick "$@" ;;
  send) shift; cmd_send "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1 (try --help)" ;;
esac
