#!/usr/bin/env -S python3 -I -S
# fm-tool-ring.py - the ONE owner of a worker's tool-event ring and its loop
# detector.
#
#   fm-tool-ring.py append <state-dir> <id>        (hook: payload JSON on stdin)
#   fm-tool-ring.py detect <state-dir> <id> [--codex-rollout PATH] [--now EPOCH]
#
# THE RING. state/<id>.tool-ring.jsonl holds at most RING_MAX (20) events,
# oldest first, one JSON object per line, replaced atomically under
# state/<id>.tool-ring.jsonl.lock:
#   {"v":1,"ts":<epoch seconds, float>,"src":"claude-hook"|"agy-hook"|"codex-rollout",
#    "kind":"tool"|"message"|"compact","tool":"<tool name or empty>",
#    "sig":"<12 hex: hash of tool name + canonical input, or of message text>",
#    "out":"<12 hex: hash of the tool output or error text, or empty>",
#    "error":true|false,"status":<401|403|429|null>,"context":true|false}
# Only names and hashes are kept, never tool input, output, or message text, so
# the ring can be read by any supervisor or judge without carrying secrets.
# status is an HTTP status found in a failed call's error text (401, 403, 429);
# context is true when that error text reports a full context window.
#
# append reads one native hook payload. Claude: PostToolUse (a successful
# call), PostToolUseFailure (error true, from .error), Stop (a message event
# from .last_assistant_message), PreCompact (a compact event). agy: PostToolUse
# with .toolCall {name, args} and .error (agy sends no tool output, so out
# hashes the error text and is the same for every successful call). Anything
# else is ignored. It always exits 0 and prints nothing, so it can never block or
# alter the worker's turn.
#
# A Codex worker needs no hook: detect --codex-rollout derives the same events
# from the tail (ROLLOUT_TAIL_BYTES) of the task-private rollout, where
# function_call / custom_tool_call items pair with their outputs by call_id
# (error when the output reports a nonzero exit code), assistant messages are
# message events, and compacted records are compact events. Its last
# token_count gives context_pct.
#
# THE DETECTOR prints exactly one line of space-separated key=value fields:
#   verdict=loop|none pattern=<name>|- events=<n> first_ts=<epoch>|-
#   last_ts=<epoch>|- context_pct=<0-100>|- last_error_status=<code>|-
# Patterns, after OpenHands' StuckDetector, checked in this order over the
# newest events:
#   repeat_action_error        the last 3 tool events: same sig, all errors
#   repeat_action_observation  the last 4 tool events: same sig and same out
#   alternating                the last 6 tool events alternate two distinct
#                              (sig, out) pairs A B A B A B
#   monologue                  the last 3 events are identical message events
#   context_loop               the last 3 events are compact events, or failed
#                              calls whose error text reports a full context
# A pattern counts only when its events all fall inside LOOP_WINDOW_SECS (600)
# of --now, so an old loop the worker has since left reads none. context_pct
# is reported, never acted on here. The detector is read-only and acts on
# nothing; bin/fm-watch.sh treats a loop verdict on a busy pane as a wedge
# suspect at once instead of after BUSY_TURN_MAX_SECS (busy_turn_over_age).
import hashlib
import json
import os
import re
import sys
import time

RING_MAX = 20
LOOP_WINDOW_SECS = 600
ROLLOUT_TAIL_BYTES = 4 * 1024 * 1024
ID_RE = re.compile(r'^[A-Za-z0-9][A-Za-z0-9._-]*$')
STATUS_RE = re.compile(r'(?<![0-9])(401|403|429)(?![0-9])')
CONTEXT_RE = re.compile(r'(?i)(context[ _-]?(window|length)[ _-]?(exceeded|too long)|prompt is too long|context_length_exceeded)')
EXIT_RE = re.compile(r'(?i)exit(?:ed)?(?: with)? code:? *([0-9]+)')


def digest(value):
    if not isinstance(value, str):
        value = json.dumps(value, sort_keys=True, separators=(',', ':'), default=str)
    return hashlib.sha1(value.encode('utf-8', 'replace')).hexdigest()[:12]


def text_of(value):
    return value if isinstance(value, str) else json.dumps(value, sort_keys=True, default=str)


def event(kind, src, ts, tool='', sig='', out='', error=False, status=None, context=False):
    return {'v': 1, 'ts': round(ts, 3), 'src': src, 'kind': kind, 'tool': tool,
            'sig': sig, 'out': out, 'error': bool(error), 'status': status, 'context': bool(context)}


def status_of(text):
    match = STATUS_RE.search(text or '')
    return int(match.group(1)) if match else None


def from_agy(payload, now):
    call = payload.get('toolCall') if isinstance(payload.get('toolCall'), dict) else {}
    tool = str(call.get('name') or '')
    err = text_of(payload.get('error') or '')
    return event('tool', 'agy-hook', now, tool, digest([tool, call.get('args')]), digest(err), bool(err),
                 status_of(err) if err else None, bool(CONTEXT_RE.search(err)))


def from_claude(payload, now):
    if payload.get('hookEventName') == 'PostToolUse' and 'toolCall' in payload:
        return from_agy(payload, now)
    name = payload.get('hook_event_name')
    if name in ('PostToolUse', 'PostToolUseFailure'):
        tool = str(payload.get('tool_name') or '')
        sig = digest([tool, payload.get('tool_input')])
        if name == 'PostToolUse':
            return event('tool', 'claude-hook', now, tool, sig, digest(payload.get('tool_response')))
        err = text_of(payload.get('error') or '')
        return event('tool', 'claude-hook', now, tool, sig, digest(err), True, status_of(err),
                     bool(CONTEXT_RE.search(err)))
    if name == 'Stop' and isinstance(payload.get('last_assistant_message'), str):
        return event('message', 'claude-hook', now, '', digest(payload['last_assistant_message'].strip()))
    if name == 'PreCompact':
        return event('compact', 'claude-hook', now)
    return None


def ring_path(state, task):
    return os.path.join(state, task + '.tool-ring.jsonl')


def read_ring(path):
    events = []
    try:
        with open(path, encoding='utf-8') as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except ValueError:
                    continue
                if isinstance(item, dict) and item.get('v') == 1:
                    events.append(item)
    except OSError:
        pass
    return events[-RING_MAX:]


def cmd_append(state, task):
    import fcntl
    import tempfile
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(payload, dict):
        return 0
    item = from_claude(payload, time.time())
    if item is None or not os.path.isdir(state):
        return 0
    path = ring_path(state, task)
    with open(path + '.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        events = (read_ring(path) + [item])[-RING_MAX:]
        fd, tmp = tempfile.mkstemp(prefix='.' + task + '.tool-ring.', dir=state)
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            out.write(''.join(json.dumps(e, separators=(',', ':')) + '\n' for e in events))
        os.replace(tmp, path)
    return 0


def iso_ts(value, fallback):
    try:
        import datetime
        return datetime.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    except (AttributeError, ValueError):
        return fallback


def from_codex_rollout(path):
    events, calls, context_pct = [], {}, None
    with open(path, 'rb') as handle:
        handle.seek(0, os.SEEK_END)
        size = handle.tell()
        start = max(0, size - ROLLOUT_TAIL_BYTES)
        handle.seek(start)
        blob = handle.read()
    lines = blob.split(b'\n')
    if start:
        lines = lines[1:]
    for raw in lines:
        try:
            row = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(row, dict):
            continue
        ts = iso_ts(row.get('timestamp'), 0.0)
        kind, payload = row.get('type'), row.get('payload') if isinstance(row.get('payload'), dict) else {}
        ptype = payload.get('type')
        if kind == 'compacted':
            events.append(event('compact', 'codex-rollout', ts))
        elif kind == 'event_msg' and ptype == 'token_count':
            info = payload.get('info') if isinstance(payload.get('info'), dict) else {}
            last = info.get('last_token_usage') if isinstance(info.get('last_token_usage'), dict) else {}
            window = info.get('model_context_window')
            used = last.get('input_tokens')
            if isinstance(window, int) and window > 0 and isinstance(used, int):
                context_pct = min(100, int(used * 100 / window))
        elif kind == 'response_item' and ptype in ('function_call', 'custom_tool_call'):
            name = str(payload.get('name') or '')
            calls[payload.get('call_id')] = (ts, name, digest([name, payload.get('arguments', payload.get('input'))]))
        elif kind == 'response_item' and ptype in ('function_call_output', 'custom_tool_call_output'):
            call = calls.pop(payload.get('call_id'), None)
            if call is None:
                continue
            output = text_of(payload.get('output'))
            code = EXIT_RE.search(output)
            failed = bool(code and code.group(1) != '0') or bool(CONTEXT_RE.search(output))
            events.append(event('tool', 'codex-rollout', ts, call[1], call[2], digest(output), failed,
                                status_of(output) if failed else None, bool(CONTEXT_RE.search(output))))
        elif kind == 'response_item' and ptype == 'message' and payload.get('role') == 'assistant':
            text = ''.join(c.get('text', '') for c in payload.get('content') or [] if isinstance(c, dict))
            if text.strip():
                events.append(event('message', 'codex-rollout', ts, '', digest(text.strip())))
    return events[-RING_MAX:], context_pct


def find_loop(events):
    tools = [e for e in events if e.get('kind') == 'tool']
    last3 = tools[-3:]
    if len(last3) == 3 and len({e['sig'] for e in last3}) == 1 and all(e.get('error') for e in last3):
        return 'repeat_action_error', last3
    last4 = tools[-4:]
    if len(last4) == 4 and len({(e['sig'], e['out']) for e in last4}) == 1:
        return 'repeat_action_observation', last4
    last6 = tools[-6:]
    if len(last6) == 6:
        a, b = (last6[0]['sig'], last6[0]['out']), (last6[1]['sig'], last6[1]['out'])
        pairs = [(e['sig'], e['out']) for e in last6]
        if a != b and pairs == [a, b, a, b, a, b]:
            return 'alternating', last6
    tail = events[-3:]
    if len(tail) == 3 and all(e.get('kind') == 'message' for e in tail) and len({e['sig'] for e in tail}) == 1:
        return 'monologue', tail
    if len(tail) == 3 and all(e.get('kind') == 'compact' or (e.get('error') and e.get('context')) for e in tail):
        return 'context_loop', tail
    return None, []


def cmd_detect(state, task, rollout, now):
    context_pct = None
    if rollout:
        try:
            events, context_pct = from_codex_rollout(rollout)
        except OSError:
            events = []
    else:
        events = read_ring(ring_path(state, task))
    pattern, members = find_loop(events)
    if pattern and now - members[0]['ts'] > LOOP_WINDOW_SECS:
        pattern, members = None, []
    errors = [e.get('status') for e in events if e.get('error') and e.get('status')]
    fields = [
        'verdict=' + ('loop' if pattern else 'none'),
        'pattern=' + (pattern or '-'),
        'events=%d' % len(events),
        'first_ts=' + ('%d' % members[0]['ts'] if members else '-'),
        'last_ts=' + ('%d' % members[-1]['ts'] if members else '-'),
        'context_pct=' + ('-' if context_pct is None else str(context_pct)),
        'last_error_status=' + (str(errors[-1]) if errors else '-'),
    ]
    print(' '.join(fields))
    return 0


def main(argv):
    if len(argv) >= 3 and argv[0] in ('append', 'detect') and ID_RE.match(argv[2]):
        mode, state, task, rest = argv[0], argv[1], argv[2], argv[3:]
        if mode == 'append' and not rest:
            try:
                return cmd_append(state, task)
            except Exception:  # a hook must never break the worker's turn
                return 0
        if mode == 'detect':
            rollout, now = None, time.time()
            while rest:
                flag = rest.pop(0)
                if flag == '--codex-rollout' and rest:
                    rollout = rest.pop(0)
                elif flag == '--now' and rest and re.fullmatch(r'[0-9]+(\.[0-9]+)?', rest[0]):
                    now = float(rest.pop(0))
                else:
                    break
            else:
                return cmd_detect(state, task, rollout, now)
    print('usage: fm-tool-ring.py append <state-dir> <id> | detect <state-dir> <id> '
          '[--codex-rollout PATH] [--now EPOCH] (see header)', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
