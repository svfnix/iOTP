#!/bin/bash
# Runs the TOTP / base32 / otpauth self-tests against the real app sources.
set -euo pipefail
cd "$(dirname "$0")"

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

OUT="$(mktemp -d)/iotp-selftest"
swiftc -o "$OUT" \
    tools/SelfTest/main.swift \
    Sources/iOTP/TOTP.swift \
    Sources/iOTP/Base32.swift \
    Sources/iOTP/OTPAuthURL.swift \
    Sources/iOTP/VaultStorage.swift \
    Sources/iOTP/Keychain.swift \
    Sources/iOTP/AppSettings.swift
"$OUT"
