#!/bin/bash
# CI helper: runs a command, saves its full output under ci-logs/, and turns compiler errors into
# GitHub annotations so failures are readable from the checks API.
#   scripts/ci-step.sh <name> <command...>
set -uo pipefail
name="$1"; shift
mkdir -p ci-logs
log="ci-logs/$name.log"
"$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [[ $status -ne 0 ]]; then
  count=0
  while IFS= read -r line; do
    [[ $count -ge 45 ]] && break
    if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+):\ error:\ (.*)$ ]]; then
      file="${BASH_REMATCH[1]#"$GITHUB_WORKSPACE/"}"
      echo "::error file=$file,line=${BASH_REMATCH[2]},col=${BASH_REMATCH[3]}::${BASH_REMATCH[4]}"
      count=$((count + 1))
    elif [[ "$line" =~ (error:|FAILED|XCTAssert|Fatal error|failed:) ]]; then
      echo "::error title=$name::${line:0:900}"
      count=$((count + 1))
    fi
  done < <(grep -E "error:|FAILED|XCTAssert|Fatal error|failed:" "$log" | awk '!seen[$0]++')
  [[ $count -eq 0 ]] && echo "::error title=$name::$(tail -c 900 "$log" | tr '\n' ' ')"
fi
exit $status
