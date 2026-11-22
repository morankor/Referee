# Shortcuts for the commands of plan.md section 3.4. Each target calls one script and nothing else.
.PHONY: build test run app snapshots e2e fixtures

build:
	scripts/build.sh

test:
	scripts/test.sh

run:
	scripts/run.sh

app:
	scripts/bundle.sh

snapshots:
	scripts/snapshots.sh

e2e:
	scripts/e2e-ollama.sh

fixtures:
	scripts/make-fixtures.sh
