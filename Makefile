.PHONY: all hooks check build test fmt lint app install worktrees worktrees-prune

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

# What worktrees exist, and which are provably merged and so safe to remove.
worktrees:
	@./Scripts/worktrees.sh

# Remove the merged ones and delete their branches. Never touches a worktree with
# uncommitted work or with commits that are not already on main.
worktrees-prune:
	@./Scripts/worktrees.sh --prune

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
	xcodebuild -project Caravan.xcodeproj -scheme Caravan -configuration Debug build

# Build Release and put it in /Applications, so the thing you double-click is the thing
# this checkout builds. Deliberately a different configuration from `app` above: that one
# is for acceptance runs, this one is for using.
install:
	@./Scripts/install-app.sh
