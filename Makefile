.PHONY: all hooks check build test fmt lint

# What CI runs, minus the Linux purity job.
all: build test lint check

# Install the pre-commit hook. Run once after cloning.
hooks:
	git config core.hooksPath .githooks
	@echo "Hooks installed (core.hooksPath=.githooks)"

# Documentation discipline over staged changes. CI runs the same script.
check:
	./Scripts/check-docs.sh

build:
	swift build

# Requires full Xcode. swift-testing ships with Xcode, not with Command Line
# Tools, so this cannot run on a CLT-only machine. CI's macOS runner has it.
test:
	swift test

fmt:
	swift format --in-place --recursive Sources Tests Package.swift

lint:
	swift format lint --strict --recursive Sources Tests Package.swift
