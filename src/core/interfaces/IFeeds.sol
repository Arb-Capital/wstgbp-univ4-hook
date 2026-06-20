// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IFeeds
/// @notice Minimal interfaces for the wsgem wrapper's two price feeds, used by the backstop hook to
///         read the backstop price directly and skip the wrapper's dispatch hop.
/// @dev The wsgem wrapper computes its quotes by forwarding to two immutable sub-contracts:
///        mintcost() == act.mintcost(pip.read())
///        burncost() == act.burncost(pip.read())
///        cooldown() == act.cooldown()
///      Both `pip` (the oracle price feed) and `act` (the market-timing/fee feed) are `immutable` in the
///      wrapper (set once in its constructor and never repointable), so a hook may cache them and price off them
///      directly — the result is byte-identical to `wsgem.mintcost()`/`burncost()`/`cooldown()` because
///      `mint`/`redeem` read the exact same feeds. This trades a slightly tighter coupling to the
///      wrapper's internals for one fewer external call per price read.
interface IPip {
    /// @notice The raw oracle NAV price in WAD gem-per-wsgem (un-fee-adjusted).
    function read() external view returns (uint256);
}

interface IAct {
    /// @notice The ask (mint) price for a given NAV `price`, in WAD gem-per-wsgem.
    function mintcost(uint256 price) external view returns (uint256);

    /// @notice The bid (redeem) price for a given NAV `price`, in WAD gem-per-wsgem (~25bps below ask).
    function burncost(uint256 price) external view returns (uint256);

    /// @notice The redemption cooldown in seconds. MUST be 0 for the sell backstop's redeem to settle
    ///         gem atomically within the swap.
    function cooldown() external view returns (uint256);
}
