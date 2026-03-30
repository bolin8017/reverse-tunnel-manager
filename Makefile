SCRIPTS   := scripts/setup-relay.sh scripts/setup-remote.sh scripts/setup-client.sh
LAUNCHERS := install.sh setup.sh
LIBS      := lib/common.sh

.DEFAULT_GOAL := help

.PHONY: lint check help

lint: ## Run shellcheck on all scripts and libraries
	shellcheck -x $(SCRIPTS) $(LAUNCHERS) $(LIBS)

check: ## Syntax-check all scripts and libraries
	@for f in $(SCRIPTS) $(LAUNCHERS) $(LIBS); do \
		bash -n "$$f" && echo "  $$f: OK" || exit 1; \
	done

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'
