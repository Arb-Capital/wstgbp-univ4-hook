// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal settable Chainlink-shaped feed for stateful (invariant) suites. The invariant
///         harness snapshots/restores EVM state per run, so feed state must live in ordinary
///         contract storage (`vm.etch` this over the real proxy address) rather than in
///         `vm.mockCall` registrations, whose interaction with per-run snapshot/restore and
///         discarded reverted calls under `fail_on_revert = false` is not journaled EVM state.
/// @dev ETCH PITFALL: after `vm.etch` the real aggregator proxy's storage (owner/aggregator
///      addresses in slots 0..2) is still there and would read back as garbage answer/updatedAt —
///      callers MUST initialize via `set(...)` and `setReverting(false)` immediately after etching.
contract SettableFeed {
    int256 public answer; // slot 0
    uint256 public updatedAt; // slot 1
    bool public reverting; // slot 2

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setReverting(bool reverting_) external {
        reverting = reverting_;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!reverting, "SettableFeed: reverting");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
