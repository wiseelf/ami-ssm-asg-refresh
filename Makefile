.PHONY: check fmt fmt-check validate

check: fmt-check validate
	python3 -m py_compile lambda/rollout.py
	bash -n scripts/*.sh

fmt:
	terraform fmt *.tf

fmt-check:
	terraform fmt -check *.tf

validate:
	terraform validate -no-color
