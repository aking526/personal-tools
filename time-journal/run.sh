#!/bin/bash
set -e
cd "$(dirname "$0")"
# Use Xcode's shared DerivedData rather than a project-local -derivedDataPath.
# A private path forces per-project copies of the machine-wide ModuleCache and
# SDKStatCaches (~85M) and keeps this build cache cold relative to Xcode's.
xcodebuild -scheme TimeJournal -configuration Debug build

products=$(xcodebuild -scheme TimeJournal -configuration Debug -showBuildSettings 2>/dev/null \
	| awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')
open "$products/TimeJournal.app"
