.PHONY: build test app install run dump screenshots icon clean

build:        ## Debug build
	swift build

test:         ## Run the test suite
	swift test

app:          ## Build build/ClaudeResume.app
	./scripts/build-app.sh

install:      ## Build, copy to ~/Applications and launch
	./scripts/build-app.sh --install

run: build    ## Run from the terminal (logs to stdout)
	"$$(swift build --show-bin-path)/ClaudeResume"

dump: build   ## Print the sessions the app would list
	"$$(swift build --show-bin-path)/ClaudeResume" --dump

screenshots:  ## Regenerate README screenshots from demo data
	swift build -c release
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-light.png --demo --select 1 --preview -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-dark.png --demo --dark --select 1 --preview -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-search.png --demo --query "chkout flw" -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-search-dark.png --demo --dark --query "chkout flw" -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-projects.png --demo --group project -AppleLocale en_US -AppleLanguages "(en)"
	"$$(swift build -c release --show-bin-path)/ClaudeResume" --snapshot docs/screenshot-projects-dark.png --demo --dark --group project -AppleLocale en_US -AppleLanguages "(en)"

icon:         ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift

clean:
	rm -rf .build build
