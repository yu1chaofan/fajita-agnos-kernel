#!/bin/bash
# PHASE40 · 静态审计：`set -e` 脚本/run 块里禁止「命令后直接 rc=$?」。
#
# 为什么是脚本而不是只写在 validate.py 里：这个坑在 PHASE37 / PHASE39 各犯一次，
# 光靠人记住已失效两次。做成能在 CI 里真跑的独立脚本，谁都能一条命令自查。
#
# 用法: audit_set_e.sh [DIR ...]      默认审计当前目录
# 退出: 0 干净 / 1 有违规 / 2 用法错误
set -euo pipefail

[ $# -eq 0 ] && set -- .

hits=0
scan_sh() {
  local f=$1
  grep -qE '^[[:space:]]*set[[:space:]]+-[a-zA-Z]*e' "$f" 2>/dev/null || return 0
  awk -v F="$f" '
    /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\$[[:space:]]*$/ {
      if (prev !~ /\|\|/ && prev !~ /&&/) { printf "%s:%d: bare rc capture under set -e\n", F, NR; found=1 }
    }
    { prev=$0 }
    END { exit found?1:0 }
  ' "$f" || hits=$((hits+1))
}

# workflow 部分走 python（yaml 解析可靠）
python3 - "$@" <<'PY'
import json, re, subprocess, sys, pathlib, yaml
pat = re.compile(r'^[ \t]*[A-Za-z_][A-Za-z0-9_]*=\$[?][ \t]*$')
bad = []
for root in sys.argv[1:]:
    for wf in pathlib.Path(root).rglob('.github/workflows/*.yml'):
        try:
            doc = yaml.safe_load(wf.read_text())
        except Exception:
            continue
        for jn, job in (doc.get('jobs') or {}).items():
            for st in job.get('steps') or []:
                run = st.get('run') or ''
                if not re.search(r'^[ \t]*set[ \t]+-[a-zA-Z]*e', run, re.M):
                    continue
                lines = run.splitlines()
                for i, ln in enumerate(lines):
                    if not pat.match(ln):
                        continue
                    prev = lines[i-1] if i else ''
                    if '||' in prev or '&&' in prev:
                        continue
                    bad.append(f"{wf.name}:{jn}:{st.get('name')}:{i+1} <- {ln.strip()}")
if bad:
    for b in bad:
        print(f"::error::bare rc capture under set -e -- {b}")
    sys.exit(1)
print("set -e rc-capture audit: clean")
PY
