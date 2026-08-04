.PHONY: hooks check

# Install the pre-commit hook. Run once after cloning.
hooks:
	git config core.hooksPath .githooks
	@echo "Hooks installed (core.hooksPath=.githooks)"

# Documentation discipline over staged changes. CI runs the same script.
check:
	./Scripts/check-docs.sh

# build / test / fmt / lint targets arrive with the package in prompt 1.
