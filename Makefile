SHELL := /bin/bash
TAG ?= local
VERSION ?= 1.0.0
.PHONY: test lint cluster build deploy smoke drill diagnose clean
test:
	python3 -m unittest discover -s tests -v
lint:
	helm lint charts/safe-release --strict
	python3 tests/check_chart.py
	for script in scripts/*.sh; do bash -n "$$script"; done
cluster:
	bash scripts/cluster-up.sh
build:
	bash scripts/build-load.sh $(TAG)
deploy:
	bash scripts/deploy.sh $(TAG) $(VERSION)
smoke:
	bash scripts/smoke.sh $(VERSION)
drill:
	bash scripts/drill.sh $(TAG)
diagnose:
	bash scripts/diagnose.sh
clean:
	kind delete cluster --name safe-release-demo
