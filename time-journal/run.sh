#!/bin/bash
set -e
xcodebuild -scheme TimeJournal -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/TimeJournal.app
