#!/bin/zsh
set -eu
repo_root=${0:A:h:h:h:h}
task_package=$(mktemp -d "${TMPDIR:-/tmp}/chengmu-catalog.XXXXXX")
trap 'rm -rf "$task_package"' EXIT
mkdir -p "$task_package/Sources/CinemaCore" "$task_package/Tests/CinemaCoreTests"
cp "$repo_root"/Sources/CinemaCore/*.swift "$task_package/Sources/CinemaCore/"
filter_args=(--filter CatalogDiscoveryPolicyTests)
if [[ "${1:-}" == "--all-core" ]]; then
    cp "$repo_root"/Tests/CinemaCoreTests/*.swift "$task_package/Tests/CinemaCoreTests/"
    filter_args=()
else
    cp "$repo_root/Tests/CinemaCoreTests/CatalogDiscoveryPolicyTests.swift" "$task_package/Tests/CinemaCoreTests/"
fi
cat > "$task_package/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "CatalogPolicyValidation", platforms: [.macOS("15.0")], targets: [.target(name: "CinemaCore"), .testTarget(name: "CinemaCoreTests", dependencies: ["CinemaCore"])], swiftLanguageVersions: [.v5])
PACKAGE
# Match scripts/swift.sh's CLT compatibility workaround without touching its
# project-local build state or invoking Python outside the requested conda env.
manifest_source="$(xcode-select -p)/usr/lib/swift/pm/ManifestAPI"
mkdir -p "$task_package/swiftpm-libs/ManifestAPI"
rsync -a --exclude="*private.swiftinterface" "$manifest_source/" "$task_package/swiftpm-libs/ManifestAPI/"
export SWIFTPM_CUSTOM_LIBS_DIR="$task_package/swiftpm-libs"
swift test -Xswiftc -plugin-path -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing" --package-path "$task_package" "${filter_args[@]}"
