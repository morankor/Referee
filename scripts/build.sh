#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STALE=(/Library/Developer/CommandLineTools/usr/lib/swift/pm/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface)
if [[ -e "${STALE[0]}" ]]; then
  echo "build.sh: stale SwiftPM interface files from an old Command Line Tools install will break every Package.swift. Remove them:" >&2
  echo "  sudo rm /Library/Developer/CommandLineTools/usr/lib/swift/pm/{ManifestAPI/PackageDescription,PluginAPI/PackagePlugin}.swiftmodule/*.private.swiftinterface" >&2
fi
exec swift build "$@"
