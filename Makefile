# tGBP/wstGBP Uniswap V4 backstop hook — dev tasks.
# Coverage targets ported from ../maseer-one.

# Excluded from coverage: the test suite, the deploy script, and the vendored
# BaseHook (third-party). Leaves only the first-party audited surface.
COVERAGE_EXCLUDE := (test/|script/|src/base/)

.PHONY: build test fmt clean coverage gen-report serve-report

build :; forge build

test  :; forge test -vvv

fmt   :; forge fmt

clean :; forge clean

# Summary coverage to the terminal. Forge disables optimizer/viaIR here for more
# accurate source maps.
coverage :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)"

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info.
gen-report :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the HTML report at http://localhost:8000 — opening index.html directly in a
# Flatpak/Snap browser routes through the document portal, which only shares that one
# file with the sandbox and so drops the report's CSS/images. HTTP avoids that.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report
