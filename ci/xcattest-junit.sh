#!/bin/bash
#
# ci/xcattest-junit.sh <result_dir> <out_junit_xml>
#
# Converts xCAT-test result logs (xcattest.log*) into a JUnit XML file that
# Jenkins (company-ci ciWithReportPublishing -> junit reports/junit/**/*.xml)
# can ingest. Parses lines of the form:
#   ------END::<case>::Passed|Failed::Time:<ts>::Duration::<n> sec------
set -euo pipefail

RESULT_DIR="${1:?usage: xcattest-junit.sh <result_dir> <out.xml>}"
OUT="${2:?usage: xcattest-junit.sh <result_dir> <out.xml>}"
mkdir -p "$(dirname "$OUT")"

python3 - "$RESULT_DIR" "$OUT" <<'PY'
import sys, re, glob, os, html
result_dir, out = sys.argv[1], sys.argv[2]
rx = re.compile(r'------END::(?P<name>[^:]+)::(?P<status>Passed|Failed)::.*?Duration::\s*(?P<dur>\d+)\s*sec', re.I)
# A case xcattest drops for a missing $$attribute logs "<case> miss attribute <attr>"
# and emits NO ------END:: marker; surface those as <skipped> so a silently-dropped
# install case (e.g. SN_setup_case) is visible in the report instead of vanishing.
skip_rx = re.compile(r'^(?P<name>\S+)\s+miss attribute\s+(?P<attr>\S+)', re.M)
cases = []
skips = {}
for log in sorted(glob.glob(os.path.join(result_dir, 'xcattest.log*')) +
                  glob.glob(os.path.join(result_dir, 'xcattest-console.log'))):
    try:
        text = open(log, errors='replace').read()
    except OSError:
        continue
    for m in rx.finditer(text):
        cases.append((m.group('name'), m.group('status').lower(), int(m.group('dur'))))
    for m in skip_rx.finditer(text):
        skips.setdefault(m.group('name'), m.group('attr'))
ran = {n for n, _, _ in cases}
skips = {n: a for n, a in skips.items() if n not in ran}   # a case that later ran is not skipped
fail = sum(1 for _, s, _ in cases if s == 'failed')
total = len(cases) + len(skips)
lines = ['<?xml version="1.0" encoding="UTF-8"?>']
lines.append(f'<testsuite name="xcat-test" tests="{total}" failures="{fail}" errors="0" skipped="{len(skips)}">')
for name, status, dur in cases:
    nm = html.escape(name)
    if status == 'failed':
        lines.append(f'  <testcase classname="xcattest" name="{nm}" time="{dur}">'
                     f'<failure message="case failed">{nm} reported Failed</failure></testcase>')
    else:
        lines.append(f'  <testcase classname="xcattest" name="{nm}" time="{dur}"/>')
for name, attr in sorted(skips.items()):
    nm = html.escape(name)
    msg = html.escape(f'skipped: miss attribute {attr}')
    lines.append(f'  <testcase classname="xcattest" name="{nm}" time="0">'
                 f'<skipped message="{msg}"/></testcase>')
lines.append('</testsuite>')
open(out, 'w').write('\n'.join(lines) + '\n')
print(f'[junit] {len(cases)} cases, {fail} failures, {len(skips)} skipped -> {out}')
PY
