# ultrablitz — release & test targets.
# `make help` lists targets. `make smoke` talks to the REAL Codex API (opt-in).

SHELL := /bin/bash
VERSION := $(shell cat VERSION)
LAST_SMOKE := tests/fixtures/companion/last-smoke.json

.PHONY: help test lint smoke release-check tag

help: ## default: list targets
	@echo "ultrablitz v$(VERSION) — targets:"
	@echo "  make test           run the full offline suite (stub companion, no API spend)"
	@echo "  make lint           shellcheck all shell sources (skips if shellcheck absent)"
	@echo "  make smoke          ONE real Codex turn against the live API (opt-in, costs money)"
	@echo "  make release-check  test + smoke — run before tagging a release"
	@echo "  make tag            verify release evidence, then PRINT the git tag command"

test:
	bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck hooks/*.sh install.sh tests/*.sh; \
	else \
		echo "shellcheck not installed — skipping"; \
	fi

smoke:
	bash tests/smoke.sh

release-check: test smoke

# `make tag` never tags. It verifies the release evidence and prints the
# command for the human to run — tagging stays a human act.
tag:
	@if [ ! -f "$(LAST_SMOKE)" ]; then \
		echo "tag: REFUSED — $(LAST_SMOKE) does not exist."; \
		echo "tag: run 'make release-check' (or 'make smoke') against the real companion first;"; \
		echo "tag: a release must carry evidence of a passing live smoke test."; \
		exit 1; \
	fi
	@if [ "$$(jq '.schemaDiff | length' "$(LAST_SMOKE)" 2>/dev/null)" != "0" ]; then \
		echo "tag: REFUSED — $(LAST_SMOKE) records a non-empty schemaDiff (or is unreadable)."; \
		echo "tag: reconcile the companion contract, re-record fixtures, and re-run 'make smoke'."; \
		exit 1; \
	fi
	@stale="$$(find hooks references/prompts -type f -newer "$(LAST_SMOKE)" -print)"; \
	if [ -n "$$stale" ]; then \
		echo "tag: REFUSED — these files changed AFTER the last smoke test:"; \
		echo "$$stale" | sed 's/^/tag:   /'; \
		echo "tag: re-run 'make smoke' so the release evidence covers them."; \
		exit 1; \
	fi
	@echo "tag: release evidence ok (smoke $$(jq -r '.date' "$(LAST_SMOKE)"), codex $$(jq -r '.codexVersion' "$(LAST_SMOKE)"))."
	@echo "tag: run this yourself:"
	@echo "  git tag -a v$(VERSION) -m \"ultrablitz v$(VERSION)\""
