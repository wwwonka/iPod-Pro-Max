#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
check_binary="${TMPDIR:-/tmp}/ippm-window-reopen-check"
xcrun swiftc -parse-as-library -o "$check_binary" 'iPod Pro Max/UI/MacWindowLifecycle.swift' Tools/WindowReopenCheck/main.swift
"$check_binary"
