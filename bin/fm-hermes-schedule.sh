#!/usr/bin/env bash
# fm-hermes-schedule.sh - user LaunchAgent templates for the digest and port check.
#
# print-digest and print-health write one plist to stdout.
# install writes both plists into --launch-agents-dir and does not load them.
# status reports whether those plist files exist. It does not call launchctl.
# uninstall deletes only those two plists. It does not boot out a loaded job.
# The real user LaunchAgents directory is refused unless
# FM_HERMES_SCHEDULE_ALLOW_USER_AGENT=1. Firstmate sets that only when
# installing after the local branch has landed.
#
# StartCalendarInterval is hour 7 minute 0, which is 07:00 in the Mac's
# local timezone and follows Europe/London daylight-saving time when that
# timezone is Europe/London. The port check uses StartInterval 1800.
# Program arguments and logs are absolute paths under FM_HOME.
# The environment is FM_HOME and a minimal PATH. Nothing sources a shell
# profile or a credential file. RunAtLoad is false.
# When config/hermes-digest-source or FM_HERMES_DIGEST_SOURCE is set, the
# digest plist copies that source into its environment.
#
# Usage:
#   fm-hermes-schedule.sh print-digest
#   fm-hermes-schedule.sh print-health
#   fm-hermes-schedule.sh install --launch-agents-dir <absolute-dir>
#   fm-hermes-schedule.sh status --launch-agents-dir <absolute-dir>
#   fm-hermes-schedule.sh uninstall --launch-agents-dir <absolute-dir>
set -euo pipefail

umask 077

DIGEST_LABEL=dev.firstmate.hermes-daily-digest
HEALTH_LABEL=dev.firstmate.grokbot-port-health

usage() {
  cat >&2 <<'EOF'
Usage:
  fm-hermes-schedule.sh print-digest
  fm-hermes-schedule.sh print-health
  fm-hermes-schedule.sh install --launch-agents-dir <absolute-dir>
  fm-hermes-schedule.sh status --launch-agents-dir <absolute-dir>
  fm-hermes-schedule.sh uninstall --launch-agents-dir <absolute-dir>
EOF
  exit 2
}

help_text() {
  cat <<'EOF'
Write or remove the user LaunchAgent plists for the morning digest and the
Grok Bot port check. This command never loads or bootstraps a job.
Hour 7 and minute 0 follow the Mac timezone. Set that timezone to
Europe/London so 07:00 follows London daylight-saving time.
EOF
}

xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

require_home() {
  local home=${FM_HOME:-}
  case "$home" in
    /*) ;;
    *) printf '%s\n' 'error: FM_HOME must be an absolute path' >&2; exit 2 ;;
  esac
  [ -d "$home" ] || { printf '%s\n' 'error: FM_HOME is not a directory' >&2; exit 2; }
}

schedule_path() {
  if [ -n "${FM_HERMES_SCHEDULE_PATH:-}" ]; then
    printf '%s' "$FM_HERMES_SCHEDULE_PATH"
    return 0
  fi
  printf '%s' '/usr/bin:/bin:/usr/sbin:/sbin'
}

source_env_lines() {
  local spec=${FM_HERMES_DIGEST_SOURCE:-} cfg
  if [ -z "$spec" ] && [ -f "$FM_HOME/config/hermes-digest-source" ] && [ ! -L "$FM_HOME/config/hermes-digest-source" ]; then
    cfg=$FM_HOME/config/hermes-digest-source
    spec=$(head -n 1 "$cfg" | tr -d '\r')
  fi
  if [ -n "$spec" ]; then
    printf '  <key>FM_HERMES_DIGEST_SOURCE</key>\n'
    printf '  <string>%s</string>\n' "$(xml_escape "$spec")"
  fi
}

plist_header() {  # <label> <script> <stdout> <stderr> <calendar-or-interval-xml>
  local label=$1 script=$2 out=$3 err=$4 when=$5 path home
  path=$(schedule_path)
  home=$FM_HOME
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$script")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>FM_HOME</key>
    <string>$(xml_escape "$home")</string>
    <key>PATH</key>
    <string>$(xml_escape "$path")</string>
$(source_env_lines)
  </dict>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$home")</string>
${when}
  <key>RunAtLoad</key>
  <false/>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$out")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$err")</string>
</dict>
</plist>
EOF
}

digest_plist() {
  local when
  when=$(cat <<'EOF'
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>7</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
EOF
)
  plist_header "$DIGEST_LABEL" \
    "$FM_HOME/bin/fm-hermes-daily-digest.sh" \
    "$FM_HOME/data/hermes-bridge/digest-launchd.out" \
    "$FM_HOME/data/hermes-bridge/digest-launchd.err" \
    "$when"
}

health_plist() {
  local when
  when=$(cat <<'EOF'
  <key>StartInterval</key>
  <integer>1800</integer>
EOF
)
  plist_header "$HEALTH_LABEL" \
    "$FM_HOME/bin/fm-grokbot-port-health.sh" \
    "$FM_HOME/data/hermes-bridge/grokbot-port-health-launchd.out" \
    "$FM_HOME/data/hermes-bridge/grokbot-port-health-launchd.err" \
    "$when"
}

require_dir_arg() {
  local dir=${1:-}
  case "$dir" in
    /*) ;;
    *) printf '%s\n' 'error: --launch-agents-dir must be an absolute path' >&2; exit 2 ;;
  esac
  user_agents=${HOME:-}/Library/LaunchAgents
  if [ "$dir" = "$user_agents" ] && [ "${FM_HERMES_SCHEDULE_ALLOW_USER_AGENT:-}" != 1 ]; then
    printf '%s\n' 'error: refusing to write the user LaunchAgents directory without FM_HERMES_SCHEDULE_ALLOW_USER_AGENT=1' >&2
    exit 2
  fi
  printf '%s' "$dir"
}

write_plist() {  # <dir> <name>
  local dir=$1 name=$2 tmp
  tmp=$(mktemp "$dir/.$name.XXXXXX")
  cat > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$dir/$name.plist"
}

cmd=${1:-}
case "$cmd" in
  --help|-h) help_text; exit 0 ;;
  print-digest|print-health|install|status|uninstall) shift ;;
  *) usage ;;
esac

require_home

case "$cmd" in
  print-digest) digest_plist; exit 0 ;;
  print-health) health_plist; exit 0 ;;
esac

dir=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --launch-agents-dir)
      [ "$#" -ge 2 ] || usage
      dir=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
dir=$(require_dir_arg "$dir")

case "$cmd" in
  install)
    mkdir -p "$dir"
    digest_plist | write_plist "$dir" "$DIGEST_LABEL"
    health_plist | write_plist "$dir" "$HEALTH_LABEL"
    printf 'installed %s\n' "$dir/$DIGEST_LABEL.plist"
    printf 'installed %s\n' "$dir/$HEALTH_LABEL.plist"
    ;;
  status)
    for name in "$DIGEST_LABEL" "$HEALTH_LABEL"; do
      if [ -f "$dir/$name.plist" ]; then
        printf 'present %s\n' "$dir/$name.plist"
      else
        printf 'absent %s\n' "$dir/$name.plist"
      fi
    done
    ;;
  uninstall)
    for name in "$DIGEST_LABEL" "$HEALTH_LABEL"; do
      if [ -f "$dir/$name.plist" ]; then
        rm -f "$dir/$name.plist"
        printf 'removed %s\n' "$dir/$name.plist"
      else
        printf 'absent %s\n' "$dir/$name.plist"
      fi
    done
    ;;
esac
