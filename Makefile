.DEFAULT_GOAL := help

IMAGE ?= localhost/tipboot
VERSION ?= dev
REVISION ?= $(shell git rev-parse --verify HEAD 2>/dev/null || printf '%s' unknown)
IMAGE_REF ?= $(IMAGE):$(VERSION)
CONTAINER_ENGINE ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null || command -v nerdctl 2>/dev/null)
BUILD_FLAGS ?=
RUN_FLAGS ?= --rm
SMOKE_COMMIT ?= adc218676eef25575469234709c2d87185ca223a
SMOKE_OUTPUT ?= $(CURDIR)/out/smoke-pinned
SMOKE_CACHE ?= $(CURDIR)/cache

.PHONY: help check-engine build image lint test validate validate-files validate-image version health shell smoke-pinned

help:
	@printf '%s\n' \
		'Tipboot container targets:' \
		'  make image           Build the Fedora 44 tool image' \
		'  make validate        Check files, build the image, and validate it' \
		'  make validate-files  Run local syntax and metadata checks' \
		'  make validate-image  Build and validate labels, tools, user, and contents' \
		'  make test            Run the host-wrapper and orchestrator unit tests' \
		'  make version         Print the version reported by the image' \
		'  make health          Run the image toolchain health check' \
		'  make shell           Open an interactive shell with this repo mounted' \
		'  make smoke-pinned    Build and boot an immutable Linux v6.12 checkout' \
		'' \
		'Overrides: CONTAINER_ENGINE, IMAGE, IMAGE_REF, VERSION, REVISION,' \
		'           BUILD_FLAGS, RUN_FLAGS, SMOKE_COMMIT, SMOKE_OUTPUT,' \
		'           SMOKE_CACHE'

check-engine:
	@if [ -z "$(strip $(CONTAINER_ENGINE))" ]; then \
		printf '%s\n' 'error: install Podman, Docker, or nerdctl, or set CONTAINER_ENGINE' >&2; \
		exit 1; \
	fi

build: image

image: check-engine
	$(CONTAINER_ENGINE) build $(BUILD_FLAGS) \
		--build-arg VERSION="$(VERSION)" \
		--build-arg REVISION="$(REVISION)" \
		--file Containerfile \
		--tag "$(IMAGE_REF)" \
		.

lint: validate-files

test: image
	@tar -cf - scripts smoke-init tests | \
		$(CONTAINER_ENGINE) run $(RUN_FLAGS) -i \
			--entrypoint /bin/bash \
			"$(IMAGE_REF)" -euo pipefail -c \
			'mkdir /tmp/tipboot-tests; \
			tar -xf - -C /tmp/tipboot-tests; \
			cd /tmp/tipboot-tests; \
			for test_script in tests/test-*.sh; do \
				"$$test_script"; \
			done'

validate: validate-files validate-image test

validate-files:
	@test -s Containerfile
	@test -s Makefile
	@test -s .gitignore
	@test -s LICENSE
	@test -x scripts/version
	@sh -n scripts/version
	@grep -q '^FROM registry\.fedoraproject\.org/fedora:44$$' Containerfile
	@grep -q 'org\.opencontainers\.image\.source="https://github.com/xjamesmorris/tipboot"' Containerfile
	@grep -q '^                                 Apache License$$' LICENSE

validate-image: image
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint /usr/local/bin/tipboot-version \
		"$(IMAGE_REF)" --healthcheck
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint /usr/local/libexec/tipboot/build-initramfs \
		"$(IMAGE_REF)" \
		--kernel-release 0.0.0-tipboot \
		--output /tmp/initramfs.cpio
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint shellcheck \
		"$(IMAGE_REF)" /usr/local/bin/tipboot-version
	@uid="$$($(CONTAINER_ENGINE) run $(RUN_FLAGS) --entrypoint id "$(IMAGE_REF)" -u)"; \
		if [ "$$uid" -eq 0 ]; then \
			printf 'error: image runs as root (uid %s)\n' "$$uid" >&2; \
			exit 1; \
		fi
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint /bin/sh \
		"$(IMAGE_REF)" -ec 'test -z "$$(find /workspace -mindepth 1 -print -quit)"'
	@source_label="$$($(CONTAINER_ENGINE) image inspect \
		--format '{{ index .Config.Labels "org.opencontainers.image.source" }}' \
		"$(IMAGE_REF)")"; \
		test "$$source_label" = "https://github.com/xjamesmorris/tipboot"
	@version_label="$$($(CONTAINER_ENGINE) image inspect \
		--format '{{ index .Config.Labels "org.opencontainers.image.version" }}' \
		"$(IMAGE_REF)")"; \
		test "$$version_label" = "$(VERSION)"
	@revision_label="$$($(CONTAINER_ENGINE) image inspect \
		--format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' \
		"$(IMAGE_REF)")"; \
		test "$$revision_label" = "$(REVISION)"

version: image
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint /usr/local/bin/tipboot-version \
		"$(IMAGE_REF)"

health: image
	@$(CONTAINER_ENGINE) run $(RUN_FLAGS) \
		--entrypoint /usr/local/bin/tipboot-version \
		"$(IMAGE_REF)" --healthcheck

shell: image
	$(CONTAINER_ENGINE) run $(RUN_FLAGS) -it \
		--volume "$(CURDIR):/workspace" \
		"$(IMAGE_REF)"

smoke-pinned: image
	@command -v podman >/dev/null 2>&1 || { \
		printf '%s\n' 'error: smoke-pinned requires rootless Podman' >&2; \
		exit 1; \
	}
	scripts/tipboot \
		--image "$(IMAGE_REF)" \
		--pull never \
		--commit "$(SMOKE_COMMIT)" \
		--output "$(SMOKE_OUTPUT)" \
		--cache "$(SMOKE_CACHE)"
