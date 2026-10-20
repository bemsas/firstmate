#!/usr/bin/env bash
# Fixture coverage for the report-only static reference checker's public CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fixture=$(fm_test_tmproot fm-tree-check)
python3 - "$ROOT/bin/fm-tree-check.py" "$fixture" <<'PY'
import hashlib
import subprocess
import sys
from pathlib import Path

checker, root = Path(sys.argv[1]), Path(sys.argv[2])


def put(path, text):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(text)


def run(code, *needles):
    before = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
    result = subprocess.run([sys.executable, str(checker), '--root', str(root)], capture_output=True, text=True)
    assert result.returncode == code, result
    for needle in needles:
        assert needle in result.stdout, (needle, result)
    after = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
    assert before == after, 'checker changed fixture files'
    return result.stdout


put('AGENTS.md', '''Load `alpha` before work.
Use the alpha skill.
- `alpha` - load before work.
Load this skill before work; use that skill when needed.
See `bin/helper.sh`, `docs/guide.md`, and `.agents/skills/alpha/SKILL.md`.
[guide](docs/guide.md#section) [web](https://invalid.example/docs/absent.md)
[reference][guide]
[guide]: docs/guide.md "Guide"
''')
put('.agents/skills/alpha/SKILL.md', '''---
name: alpha
description: >-
  A useful skill.
---
Load the `beta` skill.
[guide](../../../docs/guide.md)
''')
put('skills/beta/SKILL.md', '---\ndescription: External public skill.\n---\n')
put('docs/guide.md', '# Guide\n')
put('docs/with space.md', '# Spaces\n')
put('bin/helper.sh', '''#!/bin/sh
# docs/guide.md
# bin/helper.sh|bin/helper.sh)
# bin/<name>.sh bin/*.sh bin/${name}.sh bin/example-*.sh
# docs/<name>.md docs/${name}.md
# "$SCRIPT_DIR/../.agents/skills/missing/assets/template.html"
# invoke `plugin:external` skill
# bin/example-[abc].sh
# [smh]([[:space:]]+[0-9]+[smh])
# [space](../docs/with%20space.md) [angle](<../docs/with space.md>)
''')
(root / 'bin/binary').write_bytes(b'\xff\x00')
run(0, 'tree-check: 0 finding(s)')
print('ok: valid references, public skills, multiline descriptions, dynamic paths, URLs and binary files')

put('AGENTS.md', '''Load `vanished` before work.
Use the other skill.
- `gone` - load before work.
[lost](docs/lost.md#anchor)
[ref]: docs/also-lost.md
`bin/missing.sh` `.agents/skills/absent/SKILL.md` `docs/absent.md`
`.agents/skills/missing-directory`
''')
put('bin/helper.sh', '# bin/deleted.py\n# docs/deleted.md\n# bin/missing.sh|bin/also-missing.sh)\n')
out = run(1, 'missing-skill: vanished', 'missing-skill: other', 'missing-skill: gone',
          'missing-link: docs/lost.md#anchor', 'missing-link: docs/also-lost.md',
          'missing-path: bin/missing.sh', 'missing-path: .agents/skills/absent/SKILL.md',
          'missing-path: docs/absent.md', 'missing-path: bin/deleted.py',
          'missing-path: docs/deleted.md', 'missing-path: bin/also-missing.sh',
          'missing-path: .agents/skills/missing-directory')
assert out == run(1), 'output must be deterministic'
print('ok: missing skill, script, documentation and local link references with stable locations')

put('AGENTS.md', '')
put('bin/helper.sh', '# nothing to check\n')
for header in ('# No front matter\ndescription: too late', '---\nname: alpha\n---',
               '---\ndescription: # empty\n---', '---\ndescription: "  "\n---',
               '---\ndescription: >-\nname: alpha\n---', '---\ndescription: never closed'):
    put('.agents/skills/alpha/SKILL.md', header)
    run(1, 'missing-description:')
for value in ('A useful skill.', '"A useful skill."', "'A useful skill.'", '|\n  A useful skill.'):
    put('.agents/skills/alpha/SKILL.md', '---\ndescription: ' + value + '\n---\n')
    run(0)
print('ok: missing, blank, malformed and nonempty description front matter')

put('.agents/skills/alpha/SKILL.md', '---\ndescription: Useful.\n---\nLoad `ghost` before work.\n')
run(1, '.agents/skills/alpha/SKILL.md:4: missing-skill: ghost')
(root / 'AGENTS.md').unlink()
result = subprocess.run([sys.executable, str(checker), '--root', str(root)], capture_output=True, text=True)
assert result.returncode == 2 and 'AGENTS.md' in result.stderr, result
result = subprocess.run([sys.executable, str(checker), '--help'], capture_output=True, text=True)
assert result.returncode == 0 and 'report' in result.stdout.lower(), result
print('ok: cross-skill references, missing root input and CLI help')
PY
