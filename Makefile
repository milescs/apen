# Apen — build, test and run helpers.
# Uses the optional `dev-build` wrapper (routes DerivedData to external storage) when it is installed.

SHELL := /bin/bash
PROJECT := Apen.xcodeproj
SCHEME := Apen
DERIVED := build/DerivedData
KIT := Packages/ApenKit
BUNDLE_ID := com.milescs.apen
XCODEBUILD := $(shell command -v dev-build >/dev/null 2>&1 && echo "dev-build xcodebuild" || echo "xcodebuild")
DEBUG_APP := $(DERIVED)/Build/Products/Debug/Apen.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/Apen.app

.PHONY: bootstrap generate build release test integration fixtures run install models reset-tcc clean

bootstrap: ## Install XcodeGen and generate the project (signing: see Config/Local.xcconfig.example)
	@command -v xcodegen >/dev/null || brew install xcodegen
	@$(MAKE) generate

generate: ## Regenerate Apen.xcodeproj from project.yml
	xcodegen generate --quiet

build: generate ## Debug build of the app
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build

release: generate ## Release build of the app
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME) -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath $(DERIVED) -quiet build

test: ## Fast unit tests (ApenCore)
	cd $(KIT) && swift test --filter ApenCoreTests

integration: fixtures ## Model-backed tests (local models only; the CLI doubles as the cleanup helper)
	cd $(KIT) && swift build --product apen && \
	APEN_INTEGRATION=1 APEN_FIXTURES=$(CURDIR)/Fixtures/generated swift test --filter ApenEnginesTests

fixtures: ## Generate speech fixtures with macOS `say`
	./Fixtures/make-fixtures.sh

models: ## Download the speech + vocabulary models (one time)
	cd $(KIT) && swift run -c release apen models download --boost

run: build ## Build and launch the Debug app
	@pkill -x Apen 2>/dev/null || true
	open $(DEBUG_APP)

install: release ## Install the Release app into /Applications
	@pkill -x Apen 2>/dev/null || true
	rm -rf /Applications/Apen.app
	cp -R $(RELEASE_APP) /Applications/Apen.app
	open /Applications/Apen.app

reset-tcc: ## Forget Microphone/Accessibility grants (re-prompts on next use)
	-tccutil reset Microphone $(BUNDLE_ID)
	-tccutil reset Accessibility $(BUNDLE_ID)
	-tccutil reset PostEvent $(BUNDLE_ID)

clean:
	rm -rf build $(KIT)/.build
