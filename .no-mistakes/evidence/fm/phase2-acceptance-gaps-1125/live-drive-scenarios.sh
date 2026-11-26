# ---- live drive: real product commands, synthetic GitHub boundary ----
mkdir -p "$A/base"
git -C "$ROOT" archive 3474e048a291f0ff3b742c1ad25b25a80f40bfd2 bin | tar -x -C "$A/base"
BASEBIN="$A/base/bin"
MERGEBIN="$A/mergefake"
mkdir -p "$MERGEBIN"
cat > "$MERGEBIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MERGE_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*)
        # optionally let the reviewer write a blocker while the merge is running
        if [ -n "${LATE_REPORT:-}" ]; then cat "$LATE_REPORT" > "$LATE_TARGET"; fi
        printf '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"%s","baseRefName":"dev","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}\n' "$A_HEAD" ;;
      *headRefOid*) printf '%s\n' "$A_HEAD" ;;
      *isDraft*) printf '{"isDraft":false}\n' ;;
      *title,body*) printf '{"title":"fixture","body":"fixture"}\n' ;;
      *) exit 1 ;;
    esac ;;
  "pr merge") : > "$MERGE_LOG.merged" ;;
  "api graphql") printf 'state=MERGED\nmerged=true\nqueued=false\nbase=dev\n' ;;
  "api repos/acme/widget/branches/dev") printf '{"name":"dev","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}\n' ;;
  "api --paginate") printf '[{"type":"deletion"}]\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$MERGEBIN/gh"
export MERGE_LOG="$A/merge.log"

show() {  # <label> <command...>  : run and print command, exit status and output
  local label=$1 out rc=0
  shift
  out=$(accept_cmd "$@" 2>&1) || rc=$?
  printf '  [%s] exit=%s\n' "$label" "$rc"
  printf '%s\n' "$out" | sed "s|$T|\$T|g; s/^/      /" | tail -n 4
  return 0
}
merge_try() {  # <label> : the real merge entry point
  rm -f "$MERGE_LOG" "$MERGE_LOG.merged"; : > "$MERGE_LOG"
  show "fm-pr-merge.sh ($1)" env PATH="$MERGEBIN:$A_FAKE:$PATH" "$ROOT/bin/fm-pr-merge.sh" "$A_ID" "$A_URL" -- --squash
  if [ -e "$MERGE_LOG.merged" ]; then echo "      >>> gh pr merge WAS invoked: $(grep '^pr merge' "$MERGE_LOG")"
  else echo "      >>> gh pr merge was NOT invoked"; fi
}
every_entry() {
  show "passing"        "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"
  show "assert"         "$SCRIPT" assert "$A_ID" "$A_URL" "$A_HEAD"
  show "accept"         "$SCRIPT" accept "$A_ID" "$A_URL"
  show "fm-pr-check.sh" "$PR_CHECK" "$A_ID" "$A_URL"
  show "fm-crew-state.sh" env PATH="$A/crewfake:$A_FAKE:$PATH" "$ROOT/bin/fm-crew-state.sh" "$A_ID"
  merge_try "$1"
}

echo "=== setup: ship candidate, refute scout records merge, supervisor accepts ==="
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$A_HOME/data/backlog.md"
accept_reset; printf 'value = 61\n' > "$A_REPO/app.py"; accept_candidate
rm -f "$A_STATE/review-verdicts.jsonl" "$A_STATE/$A_ID.accepted.json"
prepare_review_record keeper 'Checked app.py. No blocker.' merge
record_review keeper
show "accept" "$SCRIPT" accept "$A_ID" "$A_URL"
# real tmux on a private socket gives fm-crew-state.sh a live idle pane
export TMUX_TMPDIR="$A/tmux" NM_HOME="$A/nm-home"; unset TMUX; mkdir -p "$TMUX_TMPDIR" "$NM_HOME" "$A/crewfake"
printf '#!/usr/bin/env bash\nexit 0\n' > "$A/crewfake/no-mistakes"; chmod +x "$A/crewfake/no-mistakes"; ln -sf "$(command -v tmux)" "$A/crewfake/tmux"
tmux -L default new-session -d -s fixture -n "fm-$A_ID" 'sleep 600'
trap 'tmux -L default kill-server 2>/dev/null; fm_test_cleanup 2>/dev/null' EXIT
printf 'window=fixture:fm-%s\n' "$A_ID" >> "$A_META"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$A_STATE" "$A_ID")
"$ROOT/bin/fm-busy-event.sh" apply "$A_STATE" "$A_ID" idle --gen "$gen" --source claude-hook --event stop
cp "$A_HOME/data/keeper/report.md" "$A/keeper.report"; cp "$A_STATE/keeper.status" "$A/keeper.status"

echo; echo "=== S1 control: current saved acceptance at every entry point ==="
every_entry control
echo; echo "=== S1b head moved after acceptance ==="
cp "$A_STATUS" "$A/ship.status"; OLD_HEAD=$A_HEAD
printf 'value = 62\n' > "$A_REPO/app.py"; accept_candidate
show "passing after new head" "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"
show "passing with old head"  "$SCRIPT" passing "$A_ID" "$A_URL" "$OLD_HEAD"
A_HEAD=$OLD_HEAD; git -C "$A_REPO" reset -q --hard "$OLD_HEAD"; cat "$A/ship.status" > "$A_STATUS"

echo; echo "=== S2: scout writes a newer fix report + status, NOT yet recorded ==="
write_report keeper fix 'Found a blocker in app.py.'; report_review keeper fix
echo "--- scout status now:"; sed "s/^/      /" "$A_STATE/keeper.status"
echo "--- BASE commit 3474e048 code, same state:"
show "BASE passing" "$BASEBIN/fm-done-check.sh" passing "$A_ID" "$A_URL" "$A_HEAD"
show "BASE assert"  "$BASEBIN/fm-done-check.sh" assert "$A_ID" "$A_URL" "$A_HEAD"
echo "--- TARGET commit code:"
every_entry displaced

echo; echo "=== S3: restore exact saved report/status; retry of same review is a no-op ==="
cat "$A/keeper.report" > "$A_HOME/data/keeper/report.md"; cat "$A/keeper.status" > "$A_STATE/keeper.status"
before=$(sha256sum < "$A_STATE/review-verdicts.jsonl")
show "record same review again" "$A_VERDICT" refute "$A_ID" keeper "$A_HEAD"
[ "$before" = "$(sha256sum < "$A_STATE/review-verdicts.jsonl")" ] && echo "      >>> journal bytes unchanged"
report_review keeper merge
show "record repeated merge report" "$A_VERDICT" refute "$A_ID" keeper "$A_HEAD"
[ "$before" = "$(sha256sum < "$A_STATE/review-verdicts.jsonl")" ] && echo "      >>> journal bytes unchanged"
every_entry restored

echo; echo "=== S4 adversarial: blocker report lands while fm-pr-merge is already running ==="
printf 'Refute %s %s fix\n\nLate blocker.\n' "$A_BASE" "$A_HEAD" > "$A/late.md"
export LATE_REPORT="$A/late.md" LATE_TARGET="$A_HOME/data/keeper/report.md"
merge_try "late report"
unset LATE_REPORT LATE_TARGET
cat "$A/keeper.report" > "$A_HOME/data/keeper/report.md"

echo; echo "=== S5 adversarial near-miss verdict forms from a second scout (never recorded) ==="
prepare_review_record sneaky 'Blocker.' fix
for variant in crlf-report status-only-suffix blocked-after-fix status-only-fix other-head-control; do
  write_report sneaky fix 'Blocker.'; : > "$A_STATE/sneaky.status"
  case "$variant" in
    crlf-report) printf 'Refute %s %s fix\r\n\r\nBlocker.\r\n' "$A_BASE" "$A_HEAD" > "$A_HOME/data/sneaky/report.md"; report_review sneaky fix ;;
    status-only-suffix) printf 'done: Refute %s %s fix - see report\n' "$A_BASE" "$A_HEAD" > "$A_STATE/sneaky.status" ;;
    blocked-after-fix) printf 'Draft notes\n' > "$A_HOME/data/sneaky/report.md"; report_review sneaky fix; printf 'blocked: evidence unavailable\n' >> "$A_STATE/sneaky.status" ;;
    status-only-fix) printf 'Draft notes\n' > "$A_HOME/data/sneaky/report.md"; report_review sneaky fix ;;
    other-head-control) printf 'Refute %s %s fix\n\nOld.\n' "$A_BASE" "$A_BASE" > "$A_HOME/data/sneaky/report.md"; printf 'done: Refute %s %s fix\n' "$A_BASE" "$A_BASE" > "$A_STATE/sneaky.status" ;;
  esac
  show "passing [$variant]" "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"
done
rm -f "$A_STATE/sneaky.status" "$A_STATE/sneaky.meta" "$A_STATE/sneaky.refute.json" "$A_HOME/data/sneaky/report.md"
show "passing after removing second scout" "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"

echo; echo "=== S6: teardown of a scout holding an unrecorded blocker (real fm-teardown.sh, fake tmux/treehouse) ==="
report_review keeper fix
mv "$A_HOME/data/backlog.md" "$A/backlog.parked"
rc=0; retire_scout keeper || rc=$?
echo "  fm-teardown.sh keeper exit=$rc"; sed "s|$T|\$T|g; s/^/      /" "$A/retire.out" | tail -n 4
ls "$A_STATE" | grep '^keeper' | sed 's/^/      kept: /'
show "passing after refused teardown" "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"
write_report keeper fix 'Found a blocker in app.py.'; record_review keeper
rc=0; retire_scout keeper || rc=$?
echo "  after recording the blocker: fm-teardown.sh keeper exit=$rc; remaining keeper files: $(ls "$A_STATE" | grep '^keeper' | tr '\n' ' ')"
show "passing after retirement" "$SCRIPT" passing "$A_ID" "$A_URL" "$A_HEAD"

echo; echo "=== S7: spaced JavaScript property names (review-brief runs the pinned-test scanner) ==="
js_case() {  # <id> <source>
  accept_reset
  printf '%b\n' "$2" > "$A_REPO/src/iterator.test.js"
  pin_new_fixture_test src/iterator.test.js
  accept_candidate
  echo "--- $1: $(printf '%b' "$2" | tr '\n' ' ')"
  show "BASE   review-brief" "$BASEBIN/fm-done-check.sh" review-brief "$A_ID" "$A_URL" "base-$1"
  show "TARGET review-brief" "$SCRIPT" review-brief "$A_ID" "$A_URL" "head-$1"
}
js_case spaced-if        'const half = rows. if(total) / test.skip("later", check) / 2;'
js_case spaced-newline   'const half = rows\n  .\n  while(total) / test.only("later", check) / 2;'
js_case spaced-comment   'const half = rows?. /* n */ for(total) / it.skip("later", check) / 2;'
js_case line-comment     'const half = rows. // n\n  if(total) / test.skip("later", check) / 2;'
js_case spaced-return    'const half = rows . return / test.skip("later", check) / 2;'
js_case real-if-regex    'if (checkHelp) /test.skip()/.test(helpText);'
js_case real-while-regex 'while (more) /it.only()/.test(next);'
js_case real-return-regex 'const m = () => { return /test.skip()/.test(helpText); };'
js_case dot-before-real-if 'if (rows.length) /test.skip()/.test(helpText);'
js_case spread-return    'const m = () => { use(...list); return /test.skip()/.test(t); };'
