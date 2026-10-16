#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
clang -c Sources/CCrypto/ccrypto.c -o "$TEST_DIR/ccrypto.o"
sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find Sources/TokenSpend -name '*.swift' ! -name main.swift | sort)
swiftc -I Sources/CCrypto/include "${sources[@]}" \
    Tests/TokenSpendTests/CodexUsageTests.swift Tests/TokenSpendTests/CursorQuotaTests.swift "$TEST_DIR/ccrypto.o" \
    -lsqlite3 -o "$TEST_DIR/codex-usage-tests"
"$TEST_DIR/codex-usage-tests" "$@"
