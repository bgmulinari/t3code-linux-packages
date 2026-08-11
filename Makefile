.PHONY: check test

check:
	python3 -m compileall -q scripts tests
	bash -n scripts/build-upstream-packages.sh
	bash -n scripts/build-package-repositories.sh
	bash -n scripts/validate-packages.sh
	shellcheck scripts/*.sh

test: check
	python3 -m unittest discover -s tests -v
