BINARY_NAME := CheAppleMailMCP
ENTITLEMENTS := Sources/CheAppleMailMCP/Entitlements.plist

.PHONY: build test clean verify-developer-id install install-signed release-signed

build:
	swift build

test:
	swift test

clean:
	swift package clean

# Fail-fast if DEVELOPER_ID is missing (left-most dep on signed targets so a
# missing env var aborts before the ~30s `swift build -c release`).
verify-developer-id:
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & Notarization' for setup.}

# Local dev install, ad-hoc signed. Fast iteration for non-FDA work.
# WARNING (#211): an ad-hoc binary loses its Full Disk Access grant on every
# rebuild (TCC keys the grant to the cdhash). For a STABLE FDA grant on your
# own machine use `make install-signed` instead.
#
# rm -f forces a fresh inode: reusing an inode held open by a running
# CheAppleMailMCP process triggers "load code signature error 2" SIGKILL on the
# new binary (macOS caches code-signature hashes per inode).
install: build
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/debug/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "Installed: ~/bin/$(BINARY_NAME) (ad-hoc — FDA grant will NOT survive rebuilds; use install-signed)"

# Dev install with a Developer ID signature (NO notarization). This is the
# fast path to a STABLE Full Disk Access grant on the maintainer's own machine
# (#211): the grant binds to the signing identity, so it survives future
# `make install-signed` runs and version bumps. Notarization (for distribution
# to OTHER users) is not needed here — your own cert launches fine on your Mac.
#
# Pre-condition: DEVELOPER_ID exported. NOTARY_PROFILE is NOT required here.
install-signed: verify-developer-id
	swift build -c release
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	@if [ -f "$(ENTITLEMENTS)" ]; then \
	    codesign --force --options runtime --entitlements "$(ENTITLEMENTS)" --sign "$$DEVELOPER_ID" ~/bin/$(BINARY_NAME); \
	else \
	    codesign --force --options runtime --sign "$$DEVELOPER_ID" ~/bin/$(BINARY_NAME); \
	fi
	@echo "Installed: ~/bin/$(BINARY_NAME) (Developer ID signed — FDA grant survives rebuilds)"
	@echo "ℹ Grant Full Disk Access ONCE to ~/bin/$(BINARY_NAME); it then persists across version bumps."

# Distribution release: build universal + Developer ID sign + notarize + publish
# to GitHub. Wraps scripts/release.sh with REQUIRE_CODESIGN=1 so it refuses to
# ship an unsigned binary.
# Usage: make release-signed VERSION=vX.Y.Z
release-signed: verify-developer-id
	@: $${VERSION:?VERSION not set. Usage: make release-signed VERSION=vX.Y.Z}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & Notarization' for setup.}
	REQUIRE_CODESIGN=1 ./scripts/release.sh "$(VERSION)"
