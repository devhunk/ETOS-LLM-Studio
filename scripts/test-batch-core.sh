#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
validation_dir=$(mktemp -d "${TMPDIR:-/tmp}/etos-batch-tests.XXXXXX")
trap 'rm -rf "$validation_dir"' EXIT
mkdir -p "$validation_dir/Sources/ETOSBatchCore" "$validation_dir/Tests/ETOSBatchCoreTests"
# Compile the actual production files, without requiring Apple SDKs or replacing application code.
for file in Core/JSONValue.swift Batch/BatchModels.swift Batch/BatchJobStore.swift Batch/OpenAIBatchAdapter.swift Batch/BatchService.swift; do
    cp "$repo/ETOSCore/ETOSCore/$file" "$validation_dir/Sources/ETOSBatchCore/"
done
cp "$repo/ETOSCore/ETOSCoreTests/BatchServiceTests.swift" "$validation_dir/Tests/ETOSBatchCoreTests/"
cat > "$validation_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ETOSBatchCore", targets: [
    .target(name: "ETOSBatchCore"),
    .testTarget(name: "ETOSBatchCoreTests", dependencies: ["ETOSBatchCore"])
], swiftLanguageModes: [.v5])
PACKAGE
export CLANG_MODULE_CACHE_PATH="$validation_dir/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$validation_dir/module-cache"
swift test --package-path "$validation_dir" --scratch-path "$validation_dir/.build" \
    --cache-path "$validation_dir/cache" --config-path "$validation_dir/config" \
    --security-path "$validation_dir/security" --jobs 4
