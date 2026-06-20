# wsgem Uniswap V4 backstop hook (tGBP/wstGBP deployment) — dev tasks.
# Coverage targets cover the first-party src surface.

# Excluded from coverage: the test suite, the deploy script, and the vendored
# BaseHook (third-party). Leaves only the first-party audited surface.
COVERAGE_EXCLUDE := (test/|script/|src/v4/base/)

# The stateful fork invariant suites are slow (~10 min each on a public RPC), so they are kept off the
# default `make test` / `make coverage` paths and run explicitly via `make test-invariant` / `make test-all`.
# Matched by contract-name substring so both the v4 (`WsgemBackstopHookInvariants`) and the adapter
# (`WsgemDirectAdapterInvariants`) suites are covered wherever their files live.
INVARIANT_MATCH := Invariants

.PHONY: build test test-invariant test-all fmt clean coverage gen-report serve-report deploy deploy-dry snapshot snapshot-check

build :; forge build

# Fast suites for the dev/CI loop (feature/regression + adversarial fuzz); excludes the invariant suites.
test  :; forge test -vvv --no-match-contract "$(INVARIANT_MATCH)"

# The stateful fork invariant suites only (slow — see note above).
test-invariant :; forge test -vvv --match-contract "$(INVARIANT_MATCH)"

# Everything, including the slow invariant suite.
test-all :; forge test -vvv

fmt   :; forge fmt

# Simulate the full deploy against live mainnet state — no broadcast, no key, nothing sent. Exercises
# the mine + mined-address assert + I-02 feed-parity asserts + pool init end-to-end and writes the
# planned txs to broadcast/DeployWstGBP.s.sol/1/dry-run/. Falls back to a public RPC if ETH_RPC_URL is
# unset (same as the test suite).
deploy-dry :; forge script script/DeployWstGBP.s.sol --rpc-url $(or $(ETH_RPC_URL),https://ethereum-rpc.publicnode.com)

# Mainnet deploy: mines + CREATE2-deploys the hook (asserts address + I-02 feed parity), initializes
# the pool, deploys the router + quoter, and verifies all three on Etherscan. `--slow` waits for each
# tx to confirm before sending the next (the CREATE2 deploy must land before the pool init references
# it). Requires: ETH_RPC_URL, PK (deployer key), ETHERSCAN_API_KEY. Run `make deploy-dry` first.
deploy :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(PK)" || { echo "PK (deployer private key) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
	forge script script/DeployWstGBP.s.sol --rpc-url $(ETH_RPC_URL) --private-key $(PK) \
		--broadcast --slow --verify --etherscan-api-key $(ETHERSCAN_API_KEY)

clean :; forge clean

# Gas baseline over the fast suites (invariants excluded — their gas is run-to-run random). Regenerate
# after intentional gas changes.
snapshot :; forge snapshot --no-match-contract "$(INVARIANT_MATCH)"

# Check against the baseline. `--tolerance 1` (1%) absorbs the few-gas median drift the fork + fuzz tests
# show between runs (forked block / fuzz medians move) while still catching real regressions. Plain
# `forge snapshot --check` will flag that micro-drift and the invariant tests' missing entries — use this.
snapshot-check :; forge snapshot --check --no-match-contract "$(INVARIANT_MATCH)" --tolerance 1

# Summary coverage to the terminal. Forge disables optimizer/viaIR here for more
# accurate source maps.
coverage :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --no-match-contract "$(INVARIANT_MATCH)"

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info.
gen-report :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --no-match-contract "$(INVARIANT_MATCH)" --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the HTML report at http://localhost:8000 — opening index.html directly in a
# Flatpak/Snap browser routes through the document portal, which only shares that one
# file with the sandbox and so drops the report's CSS/images. HTTP avoids that.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report
