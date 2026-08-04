.PHONY: all hooks check build test fmt lint app

# Zero-warnings is a rule, so the compiler enforces it. Set here rather than in
# Package.swift: as a package setting it conflicts with the -suppress-warnings
# Xcode injects for dependency targets, which breaks the app build.
SWIFTFLAGS := -Xswiftc -warnings-as-errors

# What CI runs, minus the Linux purity job.
all: build test lint check app

# Install the pre-commit hook. Run once after cloning.
hooks:
	git config core.hooksPath .githooks
	@echo "Hooks installed (core.hooksPath=.githooks)"

# Documentation discipline over staged changes. CI runs the same script.
check:
	./Scripts/check-docs.sh

build:
	swift build $(SWIFTFLAGS)

# Requires full Xcode. swift-testing ships with Xcode, not with Command Line
# Tools, so this cannot run on a CLT-only machine. CI's macOS runner has it.
test:
	swift test $(SWIFTFLAGS)

fmt:
	swift format --in-place --recursive Sources Tests App Package.swift

lint:
	swift format lint --strict --recursive Sources Tests App Package.swift

# Build the macOS app. Requires Xcode; the package targets alone build with
# Command Line Tools.
app:
	xcodebuild -project irc-client.xcodeproj -scheme IRCClient -configuration Debug build
