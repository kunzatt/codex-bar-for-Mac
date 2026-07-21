#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"
test_dir=$(mktemp -d /private/tmp/codexbar-unit-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT

swiftc -parse-as-library \
  Sources/CodexBar/Models.swift \
  Sources/CodexBar/Protocol.swift \
  Sources/CodexBar/Services.swift \
  Sources/CodexBar/CodexAppServerClient.swift \
  Tests/CodexBarTests/CodexBarUnitRunner.swift \
  -o "$test_dir/CodexBarUnitRunner"

"$test_dir/CodexBarUnitRunner"
