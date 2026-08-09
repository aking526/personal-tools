#!/bin/bash
set -e
xcodebuild -scheme TimeLogger -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/TimeLogger.app
