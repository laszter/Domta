#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/domta-export-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
cat > "$test_dir/sqlpackage" <<'PY'
#!/usr/bin/python3
import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['DOMTA_EXPORT_TEST_DIR'])
response = pathlib.Path(sys.argv[1][1:])
arguments = []
for line in response.read_text().splitlines():
    key, value = line.split(':', 1)
    arguments.append(key + ':' + value[1:-1])
output = pathlib.Path(next(a[len('/TargetFile:'):] for a in arguments if a.startswith('/TargetFile:')))
(root / 'invocation.json').write_text(json.dumps(dict(arguments=arguments, permissions=response.stat().st_mode & 0o777,
    argv=sys.argv[1:], response=str(response), staging=str(output.parent))))
mode = (root / 'mode').read_text()
if mode == 'missing': sys.exit(0)
output.write_text('' if mode == 'empty' else 'schema fixture')
if mode == 'failure':
    print('fixture extraction failed', file=sys.stderr)
    sys.exit(1)
if mode == 'wait': time.sleep(10)
PY
chmod +x "$test_dir/sqlpackage"
xcrun swiftc -swift-version 5 -parse-as-library \
    Domta/Models.swift Domta/ConnectionStringParser.swift Domta/SchemaCompareModels.swift \
    Domta/SqlPackageService.swift Domta/DeployReportParser.swift Domta/DeploymentScriptFilter.swift \
    Domta/DacFxScriptService.swift Domta/DacFxHelperSource.swift \
    Tests/DacpacExportTests.swift -o "$test_dir/export-tests"
DOMTA_EXPORT_TEST_DIR="$test_dir" PATH="$test_dir:$PATH" "$test_dir/export-tests"
