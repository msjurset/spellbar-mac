APP_NAME := SpellBar
BUNDLE := $(APP_NAME).app
INSTALL_DIR := /Applications
BUNDLE_ID := com.msjurset.SpellBar

.PHONY: all build test icon bundle deploy run clean

all: build

build:
	swift build -c release

test:
	swift test

icon:
	@test -f AppIcon.icns || swift scripts/generate-icon.swift

bundle: build icon
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@BINARY=$$(find .build -path "*release/$(APP_NAME)" -type f -not -path "*.dSYM*" 2>/dev/null | head -1); \
	if [ -z "$$BINARY" ]; then BINARY=$$(find .build -name $(APP_NAME) -type f -not -path "*.dSYM*" 2>/dev/null | head -1); fi; \
	cp "$$BINARY" $(BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Info.plist $(BUNDLE)/Contents/Info.plist
	@if [ -f AppIcon.icns ]; then cp AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns; fi
	@echo "Signing application bundle..."
	@SIGN_ID=$$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"([^"]+)".*/\1/'); \
	if [ -n "$$SIGN_ID" ]; then \
		echo "Signing with: $$SIGN_ID"; \
		codesign --force --deep --options runtime --sign "$$SIGN_ID" --identifier $(BUNDLE_ID) $(BUNDLE); \
	else \
		codesign --force --deep --sign - --identifier $(BUNDLE_ID) $(BUNDLE) 2>/dev/null || true; \
	fi
	@echo "Built $(BUNDLE)"

deploy: bundle
	pkill -9 -f "$(APP_NAME).app/Contents/MacOS/$(APP_NAME)" 2>/dev/null || true
	@sleep 0.4
	@echo "Installing $(BUNDLE) to $(INSTALL_DIR)..."
	@rm -rf "$(INSTALL_DIR)/$(BUNDLE)"
	@cp -R $(BUNDLE) "$(INSTALL_DIR)/"
	@xattr -cr "$(INSTALL_DIR)/$(BUNDLE)"
	@touch "$(INSTALL_DIR)/$(BUNDLE)"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(INSTALL_DIR)/$(BUNDLE)"
	@echo "Successfully deployed to $(INSTALL_DIR)/$(BUNDLE)"
	open "$(INSTALL_DIR)/$(BUNDLE)"

run: deploy

clean:
	rm -rf .build $(BUNDLE)
