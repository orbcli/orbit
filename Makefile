.PHONY: help test test-serial lint install

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

test: ## Run tests in parallel (falls back to serial if GNU parallel is missing)
	@if command -v parallel >/dev/null 2>&1; then \
		bats tests/ --jobs 8; \
	else \
		echo "orbit: GNU parallel not found; running tests serially" >&2; \
		bats tests/; \
	fi

test-serial: ## Run tests serially (for debugging)
	bats tests/

lint: ## Run shellcheck on scripts
	shellcheck orbit.sh install.sh examples/demo/try.sh hooks/*.sh

install: ## Install orbit (e.g. make install --claude --zsh --force)
	@./install.sh $(filter-out $@,$(MAKECMDGOALS))

%:
	@:
