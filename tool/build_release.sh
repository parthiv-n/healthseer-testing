#!/usr/bin/env bash
# Produce a release-mode iOS bundle ready to be archived in Xcode.
#
# Round-8 simplification: build metadata (app_version / app_build) is
# now read at runtime via package_info_plus from CFBundleShortVersionString
# / CFBundleVersion, so this script no longer has to forward
# --dart-define values.  Xcode's archive step is free to rebuild from
# scratch — the bundle still carries the right version because Xcode
# itself reads pubspec.yaml::version through Flutter's xcconfig.
#
# Usage:
#   ./tool/build_release.sh                # release, no signing
#   ./tool/build_release.sh --release      # explicit release
#   ./tool/build_release.sh --debug        # debug, for simulator
set -euo pipefail
cd "$(dirname "$0")/.."

# Sanity-check: the pubspec version is the source of truth that
# Xcode + package_info_plus both read.  Print it so the operator can
# confirm before archiving.
VERSION_FULL=$(awk '/^version:/{print $2}' pubspec.yaml)
APP_VERSION="${VERSION_FULL%+*}"
APP_BUILD="${VERSION_FULL#*+}"

if [[ -z "$APP_VERSION" || -z "$APP_BUILD" || "$APP_VERSION" == "$APP_BUILD" ]]; then
  echo "ERROR: could not parse version from pubspec.yaml (got '$VERSION_FULL')" >&2
  exit 1
fi

MODE="${1:---release}"
echo "Building $MODE — pubspec version=$APP_VERSION build=$APP_BUILD"
echo "(runtime metadata source: package_info_plus / Info.plist)"

flutter build ios "$MODE" --no-codesign

echo "Done.  Open ios/Runner.xcworkspace, archive, and upload to App Store Connect."
echo "Xcode is free to rebuild during archive — version metadata is read at runtime."
