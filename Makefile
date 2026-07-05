# wsgem Uniswap V4 backstop hook (tGBP/wstGBP deployment) — dev tasks.
# Coverage targets cover the first-party src surface.

# Optional .env (gitignored; see .env.example). RPC precedence everywhere:
# explicit ETH_RPC_URL > ALCHEMY_API_KEY-composed Alchemy endpoint > public fallback.
# The fork suites resolve the same chain themselves (ForkBase), so direct `forge test`
# runs get it too; exporting here covers every make-invoked child process.
-include .env
ifndef ETH_RPC_URL
ifdef ALCHEMY_API_KEY
ETH_RPC_URL := https://eth-mainnet.g.alchemy.com/v2/$(ALCHEMY_API_KEY)
endif
endif
ifdef ETH_RPC_URL
export ETH_RPC_URL
endif
ifdef ALCHEMY_API_KEY
export ALCHEMY_API_KEY
endif

# Keyless forge-script invocations (dry runs, verify-only) must strip EVERY wallet-resolving env
# var a previous deploy session may have left exported — forge binds ETH_FROM/--sender,
# ETH_KEYSTORE/--keystore, ETH_KEYSTORE_ACCOUNT/--account, ETH_PASSWORD/--password, and clap
# couples them (a stray ETH_PASSWORD with the keystore stripped fails argument parsing outright).
KEYLESS := env -u ETH_FROM -u ETH_KEYSTORE -u ETH_KEYSTORE_ACCOUNT -u ETH_PASSWORD

# Excluded from coverage: the test suite, the deploy script, and the vendored
# BaseHook (third-party). Leaves only the first-party audited surface.
COVERAGE_EXCLUDE := (test/|script/|src/v4/base/)

# The stateful fork invariant suites are slow (~10 min each on a public RPC), so they are kept off the
# default `make test` / `make coverage` paths and run explicitly via `make test-invariant` / `make test-all`.
# Matched by contract-name substring so both the v4 (`WsgemBackstopHookInvariants`) and the adapter
# (`WsgemDirectAdapterInvariants`) suites are covered wherever their files live.
INVARIANT_MATCH := Invariants

# Excluded from coverage runs (not just from the report): the gas suite asserts optimizer-built
# gas numbers, which the coverage build (optimizer off) legitimately misses.
COVERAGE_SKIP := (Invariants|WethWstGbpGasTest)

.PHONY: build test test-invariant test-all fmt clean coverage gen-report serve-report deploy deploy-dry deploy-hook-helper deploy-hook-helper-dry snapshot snapshot-check \
	sim-test sim-sweep sim-data deploy-weth-hook deploy-weth-hook-dry verify-weth-hook init-weth-pool init-weth-pool-dry

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
# unset (same as the test suite). `env -u` drops any exported ETH_FROM/ETH_KEYSTORE (set for `make deploy`)
# so the keyless simulation doesn't try to unlock a keystore and fail at `vm.startBroadcast()`.
# NOTE: on a fork where the hook already exists, HookMiner skips the live address and mines the *next*
# salt, so the logged hook/PoolId here differ from the deployed ones — that's expected (a re-deploy makes
# a fresh pool). The deployed contracts remain reproducible from this source (runtime bytecode matches).
deploy-dry :; @$(KEYLESS) forge script script/DeployWstGBP.s.sol --rpc-url $(or $(ETH_RPC_URL),https://ethereum-rpc.publicnode.com)

# Mainnet deploy: mines + CREATE2-deploys the hook (asserts address + I-02 feed parity), initializes
# the pool, deploys the router + quoter + direct adapter, and verifies all four on Etherscan. `--slow`
# waits for each tx to confirm before sending the next (the CREATE2 deploy must land before the pool init
# references it). Signs from an encrypted keystore (`--keystore` + `--sender`, like ../maseer-one) — forge
# prompts for the keystore password; no raw private key on the command line or in the environment.
# Requires: ETH_RPC_URL, ETH_FROM (deployer address), ETH_KEYSTORE (keystore JSON path), ETHERSCAN_API_KEY.
# Optional: ETH_PRIO_FEE → --priority-gas-price (maxPriorityFeePerGas) and ETH_GAS_PRICE → --with-gas-price
# (maxFeePerGas); when unset, forge auto-estimates gas. (../maseer-one maps ETH_GAS_PRICE to --base-fee,
# but that sets the *simulated* block base fee, not the broadcast tx fee — --with-gas-price is the tx knob.)
# Run `make deploy-dry` first.
deploy :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
	forge script script/DeployWstGBP.s.sol --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
		$(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE)) \
		--broadcast --slow --verify --etherscan-api-key $(ETHERSCAN_API_KEY)

# Simulate the CoW-hooks helper deploy against live mainnet state — no broadcast, no key (same shape as
# deploy-dry; plain CREATE, so no miner and re-runs are harmless).
deploy-hook-helper-dry :; @$(KEYLESS) forge script script/DeployHookHelper.s.sol --rpc-url $(or $(ETH_RPC_URL),https://ethereum-rpc.publicnode.com)

# Deploy the `WsgemHookHelper` (owner-bound CoW-hook wrap/unwrap target) after the v1 system: plain
# CREATE + I-02 feed-parity + ban-list asserts + Etherscan verify. Same keystore signing as `make deploy`.
deploy-hook-helper :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required for --verify"; exit 1; }
	forge script script/DeployHookHelper.s.sol --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
		$(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE)) \
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
coverage :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --no-match-contract "$(COVERAGE_SKIP)"

# Full HTML report into docs/coverage-report/ (gitignored). Regenerates lcov.info.
gen-report :; forge coverage --no-match-coverage "$(COVERAGE_EXCLUDE)" --no-match-contract "$(COVERAGE_SKIP)" --report lcov && genhtml lcov.info --output-directory docs/coverage-report

# Serve the HTML report at http://localhost:8000 — opening index.html directly in a
# Flatpak/Snap browser routes through the document portal, which only shares that one
# file with the sandbox and so drops the report's CSS/images. HTTP avoids that.
serve-report :; python3 -m http.server 8000 --directory docs/coverage-report

# --- WETH/wstGBP replay sim (spec Phase 5; see sim/README.md) ---

# Fee-vector cross-pin + exact pool-math unit tests for the Python sim.
sim-test :; python3 -m pytest sim/tests -q

# Full parameter sweep -> sim/RESULTS.md. Needs the regime CSVs (sim/data/fetch_binance.sh).
sim-sweep :; python3 sim/run_sweep.py

# Download the regime minute bars from Binance public data (idempotent).
sim-data :; sim/data/fetch_binance.sh

# --- WETH/wstGBP dynamic-fee venue deploy (Phase 6; see DEPLOY.md for the full runbook) ---

# Simulate the hook deploy on a mainnet fork — no broadcast, no key. Mines the salt, checks the
# oracle composition corridor, and runs every post-deploy assert.
deploy-weth-hook-dry :; @$(KEYLESS) forge script script/DeployWethHook.s.sol --rpc-url $(or $(ETH_RPC_URL),https://ethereum-rpc.publicnode.com)

# Broadcast the hook deploy (keystore-signed). Owner is the multisig from construction — nothing
# to accept, nothing to transfer. Deliberately does NOT verify inline: init must follow the deploy
# IMMEDIATELY (init front-run window — DEPLOY.md §3); Etherscan verification is a separate,
# race-free step afterwards (`make verify-weth-hook`, which resumes this broadcast).
deploy-weth-hook :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	forge script script/DeployWethHook.s.sol --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
		$(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE)) \
		--broadcast --slow

# Etherscan-verify the already-broadcast hook deploy (run AFTER init-weth-pool): resumes the
# recorded broadcast, so constructor args / metadata come from run-latest.json — no re-deploy.
# Forge requires `--broadcast` + the deployer wallet alongside `--resume` (it validates wallet
# mappings up front), but SENDS NOTHING: every tx in the record is already mined, so this only
# submits the Etherscan verification. Use the same ETH_FROM/ETH_KEYSTORE that deployed.
verify-weth-hook :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (the deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	@test -n "$(ETHERSCAN_API_KEY)" || { echo "ETHERSCAN_API_KEY is required"; exit 1; }
	@forge script script/DeployWethHook.s.sol --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		--broadcast --resume --verify --etherscan-api-key $(ETHERSCAN_API_KEY)

# Simulate the INIT-ONLY pool creation (no funds move — POL is funded later via the Uniswap UI;
# see DEPLOY.md). Needs only WETH_HOOK.
init-weth-pool-dry :
	@test -n "$(WETH_HOOK)" || { echo "WETH_HOOK (deployed hook address) is required"; exit 1; }
	@$(KEYLESS) forge script script/InitWethPool.s.sol --rpc-url $(or $(ETH_RPC_URL),https://ethereum-rpc.publicnode.com)

# Broadcast the init-only pool creation (keystore-signed). One cheap tx; re-running reverts
# (pool already initialized). Funding is a Uniswap-UI action afterwards, not a script.
init-weth-pool :
	@test -n "$(ETH_RPC_URL)" || { echo "ETH_RPC_URL is required"; exit 1; }
	@test -n "$(ETH_FROM)" || { echo "ETH_FROM (deployer address) is required"; exit 1; }
	@test -n "$(ETH_KEYSTORE)" || { echo "ETH_KEYSTORE (keystore JSON path) is required"; exit 1; }
	@test -n "$(WETH_HOOK)" || { echo "WETH_HOOK (deployed hook address) is required"; exit 1; }
	forge script script/InitWethPool.s.sol --rpc-url $(ETH_RPC_URL) \
		--sender $(ETH_FROM) --keystore $(ETH_KEYSTORE) \
		$(if $(ETH_PRIO_FEE),--priority-gas-price $(ETH_PRIO_FEE)) \
		$(if $(ETH_GAS_PRICE),--with-gas-price $(ETH_GAS_PRICE)) \
		--broadcast --slow
