PYTHON ?= python3
VENOM_UPDATE := $(PYTHON) Build/venom_update.py
COMPONENT_ARG = $(if $(name),--component "$(name)",)
VERBOSE_ARG = $(if $(verbose),--verbose,)
FULL_ARG = $(if $(full),--full,)
BUILD_TIMESTAMP ?= 202001010000
NXVENOM_STAGE := Build/work/package-nxvenom
AIO_STAGE := Build/work/package-aio
.DEFAULT_GOAL := help

.PHONY: help test check-updates update update-all update-dry-run adopt-latest list-components validate build build-nxvenom build-aio release release-notes release-draft-upload clean-update-work clean-update-cache clean-zips clean

help:
	@printf "\n\033[1;36mNX-Venom automation\033[0m\n\n"
	@printf "\033[1;33mUpdate\033[0m\n"
	@printf "  \033[2m%-64s  %s\033[0m\n" "Command" "Description"
	@printf "  \033[2m%-64s  %s\033[0m\n" "----------------------------------------------------------------" "-------------------------------"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make check-updates [name=component]" "Check GitHub releases"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make update-dry-run" "Preview summary"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make update-dry-run name=component" "Preview one component"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make update-dry-run full=1" "Preview full details"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make update-dry-run full=1 name=component verbose=1" "Preview with file paths"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make update name=component" "Update one component + validate"
	@printf "  \033[1;32m%-64s\033[0m  %s\n\n" "make update-all" "Update all + validate"
	@printf "\033[1;33mBuild / Release\033[0m\n"
	@printf "  \033[2m%-64s  %s\033[0m\n" "Command" "Description"
	@printf "  \033[2m%-64s  %s\033[0m\n" "----------------------------------------------------------------" "-------------------------------"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make build" "Validate and build NXVenom.zip and AIO.zip"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make release-notes [tag=vX.Y.Z]" "Generate release notes"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make release-draft-upload tag=vX.Y.Z" "Upload existing NXVenom.zip to draft"
	@printf "  \033[1;32m%-64s\033[0m  %s\n\n" "make release-draft-upload tag=vX.Y.Z [title=...] [notes=...]" "Upload with metadata"
	@printf "\033[1;33mUtilities\033[0m\n"
	@printf "  \033[2m%-64s  %s\033[0m\n" "Command" "Description"
	@printf "  \033[2m%-64s  %s\033[0m\n" "----------------------------------------------------------------" "-------------------------------"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make list-components" "Show configured components"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make adopt-latest [name=component]" "Mark latest as accepted"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make validate" "Validate bundle structure"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make test" "Run updater unit tests (offline)"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make clean-update-work" "Remove temporary unpacked files"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make clean-update-cache" "Remove downloaded cache"
	@printf "  \033[1;32m%-64s\033[0m  %s\n" "make clean-zips" "Remove built zip files"
	@printf "  \033[1;32m%-64s\033[0m  %s\n\n" "make clean" "Remove work files and built zips"
	@printf "\033[1;33mGitHub rate limits\033[0m\n"
	@printf "  export GITHUB_TOKEN=... or run gh auth login before bulk checks\n\n"

check-updates:
	@$(VENOM_UPDATE) check $(COMPONENT_ARG)

update:
	@test -n "$(name)" || (echo "Usage: make update name=component" && exit 1)
	@$(VENOM_UPDATE) update --component "$(name)" $(VERBOSE_ARG) $(FULL_ARG)
	@$(VENOM_UPDATE) validate

update-all:
	@$(VENOM_UPDATE) update $(VERBOSE_ARG) $(FULL_ARG)
	@$(VENOM_UPDATE) validate

update-dry-run:
	@$(VENOM_UPDATE) update --dry-run $(COMPONENT_ARG) $(VERBOSE_ARG) $(FULL_ARG)

adopt-latest:
	@$(VENOM_UPDATE) adopt $(COMPONENT_ARG)

list-components:
	@$(VENOM_UPDATE) list

validate:
	@$(VENOM_UPDATE) validate

test:
	@$(PYTHON) -m unittest discover -s Build/tests -v

build: validate build-nxvenom build-aio

build-nxvenom:
	@set -e; \
	stage="$(CURDIR)/$(NXVENOM_STAGE)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	rm -rf "$$stage" "$(CURDIR)/NXVenom.zip"; \
	mkdir -p "$$stage"; \
	COPYFILE_DISABLE=1 cp -R "$(CURDIR)/Sources/NXVenom/." "$$stage/"; \
	find "$$stage" -exec touch -t "$(BUILD_TIMESTAMP)" {} +; \
	(cd "$$stage" && find . -mindepth 1 \( -type f -o -type d ! -empty \) -print | sed 's#^\./##' | grep -v '^$$' | LC_ALL=C sort | zip -qqX "$(CURDIR)/NXVenom.zip" -@)

build-aio:
	@set -e; \
	stage="$(CURDIR)/$(AIO_STAGE)"; \
	trap 'rm -rf "$$stage"' EXIT; \
	rm -rf "$$stage" "$(CURDIR)/AIO.zip"; \
	mkdir -p "$$stage"; \
	COPYFILE_DISABLE=1 cp -R "$(CURDIR)/Sources/AIO/." "$$stage/"; \
	find "$$stage" -exec touch -t "$(BUILD_TIMESTAMP)" {} +; \
	(cd "$$stage" && find . -mindepth 1 \( -type f -o -type d ! -empty \) -print | sed 's#^\./##' | grep -v '^$$' | LC_ALL=C sort | zip -qqX "$(CURDIR)/AIO.zip" -@)

release: build

release-notes:
	@$(VENOM_UPDATE) release-notes $(if $(tag),--tag "$(tag)",) $(if $(from),--from "$(from)",)

release-draft-upload:
	@test -n "$(tag)" || (echo "Usage: make release-draft-upload tag=vX.Y.Z [title='...'] [notes='...']" && exit 1)
	@test -f NXVenom.zip || (echo "NXVenom.zip not found. Run make build first." && exit 1)
	@notes_file="$$(mktemp)"; \
	trap 'rm -f "$$notes_file"' EXIT; \
	if [ -n "$(notes)" ]; then \
		printf '%s\n' "$(notes)" > "$$notes_file"; \
	else \
		$(VENOM_UPDATE) release-notes --tag "$(tag)" > "$$notes_file"; \
	fi; \
	if gh release view "$(tag)" >/dev/null 2>&1; then \
		if [ -n "$(notes)" ]; then \
			gh release edit "$(tag)" $(if $(title),--title "$(title)",) --notes-file "$$notes_file"; \
		elif [ -n "$(title)" ]; then \
			gh release edit "$(tag)" --title "$(title)"; \
		fi; \
	else \
		gh release create "$(tag)" --draft --title "$(if $(title),$(title),$(tag))" --notes-file "$$notes_file"; \
	fi
	@gh release upload "$(tag)" NXVenom.zip --clobber

clean-update-work:
	@$(VENOM_UPDATE) clean --work

clean-update-cache:
	@$(VENOM_UPDATE) clean --cache

clean-zips:
	@rm -f NXVenom.zip AIO.zip

clean: clean-update-work clean-zips
