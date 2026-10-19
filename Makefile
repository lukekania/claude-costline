.PHONY: test lint install install-dev uninstall

test: lint
	tests/run.sh

lint:
	bash -n bin/statusline.sh install.sh uninstall.sh tests/run.sh
	@if command -v shellcheck >/dev/null; then shellcheck -x bin/statusline.sh install.sh uninstall.sh tests/run.sh; else echo "shellcheck not installed, skipped"; fi
	python3 -m py_compile bin/costline.py
	python3 -I -c 'import json; json.load(open("prices.default.json"))'

install:
	./install.sh

install-dev:
	./install.sh --link

uninstall:
	./uninstall.sh
