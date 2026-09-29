# Utter — build, test and run helpers.
# Uses the optional `dev-build` wrapper (routes DerivedData to external storage) when it is installed.

SHELL := /bin/bash
PROJECT := Utter.xcodeproj
SCHEME := Utter
DERIVED := build/DerivedData
KIT := Packages/UtterKit
BUNDLE_ID := com.milescs.utter
XCODEBUILD := $(shell command -v dev-build >/dev/null 2>&1 && echo "dev-build xcodebuild" || echo "xcodebuild")
DEBUG_APP := $(DERIVED)/Build/Products/Debug/Utter.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Utter.app

.PHONY: bootstrap generate build release test integration fixtures run install models reset-tcc clean

bootstrap: ## Install tools, create local signing config, generate the project
	@command -v xcodegen >/dev/null || brew install xcodegen
	@test -f Config/Local.xcconfig || (cp Config/Local.xcconfig.example Config/Local.xcconfig && echo "Edit Config/Local.xcconfig to set your DEVELOPMENT_TEAM")
	@$(MAKE) generate

generate: ## Regenerate Utter.xcodeproj from project.yml
	xcodegen generate --quiet

build: generate ## Debug build of the app
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet build

release: generate ## Release build of the app
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -quiet build

test: ## Fast unit tests (UtterCore)
	cd $(KIT) && swift test --filter UtterCoreTests

integration: fixtures ## Model-backed tests (local models only; the CLI doubles as the cleanup helper)
	cd $(KIT) && swift build --product utter && \
	UTTER_INTEGRATION=1 UTTER_FIXTURES=$(CURDIR)/Fixtures/generated swift test --filter UtterEnginesTests

fixtures: ## Generate speech fixtures with macOS `say`
	./Fixtures/make-fixtures.sh

models: ## Download the speech + vocabulary models (one time)
	cd $(KIT) && swift run -c release utter models download --boost

run: build ## Build and launch the Debug app
	@pkill -x Utter 2>/dev/null || true
	open $(DEBUG_APP)

install: release ## Install the Release app into /Applications
	@pkill -x Utter 2>/dev/null || true
	rm -rf /Applications/Utter.app
	cp -R $(RELEASE_APP) /Applications/Utter.app
	open /Applications/Utter.app

reset-tcc: ## Forget Microphone/Accessibility grants (re-prompts on next use)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset PostEvent $(BUNDLE_ID)

clean:
	rm -rf build $(KIT)/.build
