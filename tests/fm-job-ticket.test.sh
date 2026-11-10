#!/usr/bin/env bash
# Public CLI tests for the inert software-feature ticket. All artifacts and
# image-named files are synthetic text, never browser/UI/product proof.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-job-ticket)
CLI=$ROOT/bin/fm-job-ticket.sh
A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

make_case() {
  d=$TMP_ROOT/$1
  mkdir -p "$d/home/config" "$d/home/data/job" "$d/home/state" "$d/artifacts"
  : > "$d/home/config/job-ticket"
  cat > "$d/home/data/job/brief.md" <<'EOF'
# Task
## Captain's intent
The price label wraps onto two lines on the mobile listing card. Fix it.

## Firstmate spec
SYNTHETIC feature fixture. This text is not the raw ask.
EOF
  for name in intake research production reality baseline.png after.png command; do
    printf 'SYNTHETIC fixture: %s; no browser or product verification\n' "$name" > "$d/artifacts/$name"
  done
  printf 'preserve status\n' > "$d/home/state/job.status"
  printf 'preserve metadata\n' > "$d/home/state/job.meta"
  printf 'preserve backlog\n' > "$d/home/data/backlog.md"
  printf 'preserve project\n' > "$d/project.txt"
}
cli() {
  env FM_HOME="$d/home" FM_DATA_OVERRIDE="$d/home/data" FM_CONFIG_OVERRIDE="$d/home/config" \
    FM_STATE_OVERRIDE="$d/must-not-create-state" "$CLI" "$@"
}
expect() {
  local want=$1 rc=0
  shift
  "$@" > "$TMP_ROOT/out" 2> "$TMP_ROOT/err" || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected exit $want, got $rc: $*; $(cat "$TMP_ROOT/err")"
}
json_is() { jq -e "$1" "$d/home/data/job/job-ticket.json" >/dev/null || fail "$2"; }
verdict_is() { jq -e "$1" "$TMP_ROOT/out" >/dev/null || fail "$2: $(cat "$TMP_ROOT/out")"; }
unchanged_refusal() {
  cp "$d/home/data/job/job-ticket.json" "$TMP_ROOT/before.json"
  expect 1 cli "$@"
  cmp -s "$TMP_ROOT/before.json" "$d/home/data/job/job-ticket.json" || fail 'refusal changed ticket bytes'
}
setup_strategy() {
  cli init job --size S --kind ship
  cli pass job intake --actor main --artifact "$d/artifacts/intake"
  cli truth job add --id T1 --text 'phone label on one line' --proof desktop --owner desktop
  cli truth job add --id T2 --text 'desktop unchanged' --proof desktop --owner desktop
  cli truth job add --id T3 --text 'existing checks' --proof command --owner vm-mate
  expect 3 cli check job
  verdict_is '.statuses.UNOBSERVED==3 and .statuses.PROVEN==0' 'unobserved truths were inferred'
  cli pass job research strategy --actor vm-mate --artifact "$d/artifacts/research"
}
setup_qa() {
  setup_strategy
  cli pass job production --actor worker-1 --artifact "$d/artifacts/production" --version "$A"
  cli pass job qa --actor selected-path --ref selected-path --version "$A"
}
observations() {
  local version=$1
  for truth in T1 T2; do
    cli observe job "$truth" --by desktop --status PROVEN --version "$version" \
      --baseline "$d/artifacts/baseline.png" --after "$d/artifacts/after.png" --synthetic
  done
  cli observe job T3 --by vm-mate --status PROVEN --version "$version" --evidence "$d/artifacts/command" --synthetic
}
finish() {
  cli pass job reality --actor main --artifact "$d/artifacts/reality"
  cli pass job delivery --actor main --ref 'https://example.invalid/synthetic-delivery'
  cli pass job learning --actor main --ref none
}
outside_hashes() {
  local path
  while IFS= read -r path; do
    [ "$path" = "$d/home/data/job/job-ticket.json" ] || cksum "$path"
  done < <(find "$d" -type f | sort)
}

test_ordered_walk() {
  make_case ordered
  outside_hashes > "$TMP_ROOT/outside-before"
  setup_qa
  observations "$A"
  finish
  expect 0 cli check job --version "$A"
  verdict_is '.flow=="complete" and .statuses.PROVEN==3 and .synthetic==3 and (.layers|length)==8' 'bad completed verdict'
  json_is '[.layers[].layer]==["intake","research","strategy","production","qa","reality","delivery","learning"] and all(.layers[];.state=="passed") and .ledger_frozen' 'ordered layers missing'
  json_is '.job_type=="software-feature" and .layers[3].artifact.sha256!=null and .ledger[0].observation.evidence[0].sha256!=null' 'artifact binding absent'
  outside_hashes > "$TMP_ROOT/outside-after"
  cmp -s "$TMP_ROOT/outside-before" "$TMP_ROOT/outside-after" || fail 'outside files changed'
  assert_absent "$d/must-not-create-state" 'command created state directory'
  [ "$(find "$d/home/data/job" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 2 ] || fail 'transient ticket files leaked'
  cp "$d/home/data/job/job-ticket.json" "$TMP_ROOT/complete.json"
  pass 'eight-layer synthetic walk completes with three explicit PROVEN records and no outside writes'
}
test_order_artifacts_atomicity() {
  make_case order
  cli init job --size M --kind ship
  unchanged_refusal pass job production --actor worker-1 --artifact "$d/artifacts/production" --version "$A"
  unchanged_refusal pass job intake --actor main --artifact "$d/absent"
  : > "$d/empty"
  unchanged_refusal pass job intake --actor main --artifact "$d/empty"
  unchanged_refusal pass job intake --actor main --ref invented
  unchanged_refusal pass job intake strategy --actor main --artifact "$d/artifacts/intake"
  json_is '.layers[0].state=="open"' 'multi-layer refusal partially committed'
  cli pass job intake research --actor main --artifact "$d/artifacts/research"
  unchanged_refusal pass job strategy --actor main --artifact "$d/artifacts/research"
  pass 'order, empty ledger, missing artifacts, invalid references and multi-layer refusals are atomic'
}
test_labels_and_desktop_shape() {
  make_case labels
  setup_qa
  unchanged_refusal observe job T1 --by worker-1 --status PROVEN --version "$A" --evidence "$d/artifacts/command"
  unchanged_refusal observe job T1 --by vm-mate --status PROVEN --version "$A" --evidence "$d/artifacts/command"
  unchanged_refusal observe job T1 --by desktop --status PROVEN --version "$A" --after "$d/artifacts/after.png"
  unchanged_refusal observe job T1 --by desktop --status PROVEN --version "$A" --baseline "$d/artifacts/baseline.png"
  unchanged_refusal observe job T3 --by vm-mate --status PROVEN --version "$A"
  unchanged_refusal observe job T3 --by vm-mate --status GAP --version "$A"
  # Make the maker also the declared owner; a different-label check still refuses.
  cli return job --code approach --by main
  cli truth job add --id maker --text 'maker-owned truth' --proof command --owner worker-1
  cli pass job strategy --actor main --artifact "$d/artifacts/research"
  cli pass job production --actor worker-1 --artifact "$d/artifacts/production" --version "$A"
  cli pass job qa --actor selected-path --ref selected-path
  unchanged_refusal observe job maker --by worker-1 --status NOT_RUN --version "$A" --reason unavailable
  pass 'recorded maker and owner labels plus PROVEN desktop baseline/after requirements are enforced'
}
test_honest_gaps() {
  make_case gaps
  setup_qa
  cli observe job T1 --by desktop --status NOT_RUN --version "$A" --reason 'Desktop unavailable'
  cli observe job T2 --by desktop --status NOT_DETERMINED --version "$A" --reason 'No comparison available'
  cli observe job T3 --by vm-mate --status GAP --version "$A" --reason 'Check reports a gap'
  finish
  expect 0 cli check job --version "$A"
  verdict_is '.flow=="complete" and .statuses.PROVEN==0 and .statuses.NOT_RUN==1 and .statuses.NOT_DETERMINED==1 and .statuses.GAP==1 and .synthetic==0' 'honest gaps misreported'
  json_is 'all(.ledger[];(.observation.evidence|length)==0)' 'invented capture evidence'
  pass 'honest unavailable proof needs reason but no captures and can complete bookkeeping'
}
test_freeze_and_returns() {
  make_case returns
  setup_qa
  observations "$A"
  finish
  unchanged_refusal truth job add --id T4 --text extra --proof none --owner main
  cli return job --code environment --by main --note 'fixture environment unavailable'
  json_is 'all(.layers[];.state=="passed") and .returns[-1].reopened==null' 'environment return reopened a layer'
  cli return job --code craft --by main
  json_is '.layers[3].state=="open" and all(.layers[4:][];.state=="stale") and .ledger[0].observation.state=="stale"' 'craft return failed'
  cli return job --code craft --by main
  cp "$d/home/data/job/job-ticket.json" "$TMP_ROOT/pre-escalate"
  expect 11 cli return job --code craft --by main
  json_is '.returns[-1].escalate and .returns[-1].reopened==null' 'third return not recorded as escalation'
  jq '.layers' "$TMP_ROOT/pre-escalate" > "$TMP_ROOT/layers-before"
  jq '.layers' "$d/home/data/job/job-ticket.json" > "$TMP_ROOT/layers-after"
  cmp -s "$TMP_ROOT/layers-before" "$TMP_ROOT/layers-after" || fail 'escalation reopened layers'
  expect 3 cli check job
  verdict_is '.escalate and .returns.craft==3 and .returns.environment==1' 'return counts missing'
  cli return job --code approach --by vm-mate
  cli truth job add --id T4 --text extra --proof none --owner main
  json_is '.ledger_frozen==false and .layers[2].state=="open" and (.ledger|length)==4' 'approach did not reopen ledger'
  pass 'frozen ledger, local bounded returns, escalation and environment records retain distinct semantics'
}
test_version_recovery() {
  make_case versions
  setup_qa
  observations "$A"
  finish
  expect 3 cli check job --version "$B"
  verdict_is '.flow=="stale" and .layers[5].state=="stale"' 'moved version not stale'
  cli pass job qa --actor selected-path --ref selected-path --version "$B"
  unchanged_refusal pass job reality --actor main --artifact "$d/artifacts/reality"
  cli observe job T1 --by desktop --status NOT_RUN --version "$B" --reason unavailable
  unchanged_refusal pass job reality --actor main --artifact "$d/artifacts/reality"
  observations "$B"
  finish
  expect 0 cli check job --version "$B"
  verdict_is '.flow=="complete" and .statuses.PROVEN==3' 'version recovery incomplete'
  json_is '(.layers[4].history|length)==2 and .ledger[0].history[0].version=="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" and .ledger[0].history[-1].status=="NOT_RUN"' 'version/observation history lost'
  cli return job --code proof --by main
  unchanged_refusal pass job reality --actor main --artifact "$d/artifacts/reality"
  observations "$B"
  finish
  expect 0 cli check job --version "$B"
  pass 'exact versions and same-version proof returns require fresh observations with retained history'
}
test_changed_intent_recovery() {
  make_case intent
  setup_qa
  observations "$A"
  finish
  old=$(jq -r '.intent.sha256' "$d/home/data/job/job-ticket.json")
  printf '\nAdditional build constraint.\n' >> "$d/home/data/job/brief.md"
  expect 0 cli check job --version "$A"
  verdict_is '.flow=="complete"' 'Firstmate spec was mistaken for raw intent'
  # A blank line inside the intent body is a real byte change, even though
  # command substitution would normally strip these trailing newlines.
  awk '/^## Firstmate spec/{print ""} {print}' "$d/home/data/job/brief.md" > "$d/changed-brief"
  mv "$d/changed-brief" "$d/home/data/job/brief.md"
  expect 3 cli check job --version "$A"
  verdict_is '.flow=="intent-changed" and .layers[0].state=="stale"' 'raw body change missed'
  unchanged_refusal pass job delivery --actor main --ref selected-path
  cli pass job intake --actor main --artifact "$d/artifacts/intake"
  json_is ".intent.sha256!=\"$old\" and .intent.history[0].sha256==\"$old\" and all(.layers[1:][];.state==\"stale\")" 'intent recovery lost history or descendants'
  expect 3 cli check job --version "$A"
  verdict_is '.flow=="stale"' 'new intent not accepted'
  cli pass job research strategy --actor vm-mate --artifact "$d/artifacts/research"
  cli pass job production --actor worker-1 --artifact "$d/artifacts/production" --version "$B"
  cli pass job qa --actor selected-path --ref selected-path --version "$B"
  observations "$B"
  finish
  expect 0 cli check job --version "$B"
  verdict_is '.flow=="complete"' 'full changed-intent recovery did not complete'
  cli return job --code intent --by main
  json_is '.layers[0].state=="open" and .ledger_frozen==false' 'intent return did not reopen intake/ledger'
  pass 'raw-body hash change is detected and fully recovered without conflating Firstmate spec or losing history'
}
test_artifact_changes_and_read_only() {
  make_case changed-artifact
  setup_qa
  observations "$A"
  finish
  cp "$d/home/data/job/job-ticket.json" "$TMP_ROOT/read-before"
  rm "$d/home/config/job-ticket"
  expect 0 cli show job
  cmp -s "$TMP_ROOT/read-before" "$TMP_ROOT/out" || fail 'show altered record'
  expect 0 cli check job --version "$A"
  printf 'changed synthetic artifact\n' >> "$d/artifacts/after.png"
  expect 3 cli check job --version "$A"
  verdict_is '.flow=="stale" and (.changed_artifacts|length)>0' 'changed bound artifact missed'
  cmp -s "$TMP_ROOT/read-before" "$d/home/data/job/job-ticket.json" || fail 'read-only command wrote ticket'
  assert_absent "$d/must-not-create-state" 'read-only command wrote state'
  pass 'show/check stay read-only without opt-in and changed artifact bytes report stale'
}
test_disabled_and_usage() {
  d=$TMP_ROOT/disabled
  mkdir -p "$d"
  printf 'untouched\n' > "$d/sentinel"
  for command in init truth pass observe return; do
    expect 0 cli "$command" job
    assert_contains "$(cat "$TMP_ROOT/out")" disabled 'missing disabled notice'
  done
  [ "$(find "$d" -mindepth 1 | wc -l | tr -d ' ')" = 1 ] || fail 'disabled command wrote files/directories'
  expect 1 cli show job
  expect 1 cli check job
  expect 2 env -u FM_HOME "$CLI" init job --size S --kind ship
  expect 2 cli init ../unsafe --size S --kind ship
  make_case usage
  expect 2 cli init job --size S --kind artifact
  expect 2 cli init job --size XL --kind ship
  expect 0 cli init job --size L --kind ship
  unchanged_refusal init job --size L --kind ship
  expect 2 cli pass job intake --actor 'Invalid Actor' --artifact "$d/artifacts/intake"
  expect 2 cli check job --version short
  expect 3 cli check job
  verdict_is '.flow=="incomplete" and .statuses.UNOBSERVED==0' 'empty ticket verdict wrong'
  pass 'disabled mutations write nothing; explicit home, identifiers, versions, sizes and sole job kind are validated'
}
test_missing_intent_and_overrides() {
  make_case missing-intent
  printf '# Task\n## Firstmate spec\nConstraint only.\n' > "$d/home/data/job/brief.md"
  expect 1 cli init job --size S --kind ship
  assert_absent "$d/home/data/job/job-ticket.json" 'missing intent was invented'
  printf "# Task\n## Captain's intent\n \n## Firstmate spec\nConstraint only.\n" > "$d/home/data/job/brief.md"
  expect 1 cli init job --size S --kind ship
  make_case overrides
  mkdir -p "$d/alternate-data" "$d/alternate-config"
  mv "$d/home/data/job" "$d/alternate-data/job"
  mv "$d/home/config/job-ticket" "$d/alternate-config/job-ticket"
  expect 0 env FM_HOME="$d/home" FM_DATA_OVERRIDE="$d/alternate-data" FM_CONFIG_OVERRIDE="$d/alternate-config" \
    "$CLI" init job --size M --kind ship
  assert_present "$d/alternate-data/job/job-ticket.json" 'data override ignored'
  assert_absent "$d/home/data/job" 'default data directory written'
  pass 'missing/empty raw intent refuses and explicit private data/config overrides work'
}

test_ordered_walk
test_order_artifacts_atomicity
test_labels_and_desktop_shape
test_honest_gaps
test_freeze_and_returns
test_version_recovery
test_changed_intent_recovery
test_artifact_changes_and_read_only
test_disabled_and_usage
test_missing_intent_and_overrides
