#!/bin/bash
set -e
cd "$(dirname "$0")"
xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/TimeJournal.app
