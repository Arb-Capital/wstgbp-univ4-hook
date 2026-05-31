// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IMaseerFeeds
/// @notice Minimal interfaces for the wstGBP wrapper's two price feeds, used by the hooks to read the
///         backstop price directly and skip the wrapper's dispatch hop.
/// @dev `wstGBP` (MaseerOne) computes its quotes by forwarding to two immutable sub-contracts:
///        mintcost() == act.mintcost(pip.read())
///        burncost() == act.burncost(pip.read())
///        cooldown() == act.cooldown()
///      Both `pip` (oracle) and `act` (MaseerGate: market timing + fees) are `immutable` in MaseerOne
///      (set once in its constructor and never repointable), so a hook may cache them and price off them
///      directly — the result is byte-identical to `wstGBP.mintcost()`/`burncost()`/`cooldown()` because
///      `mint`/`redeem` read the exact same feeds. This trades a slightly tighter coupling to the
///      wrapper's internals for one fewer external call per price read.
///
///      Reference: ../maseer-one/src/MaseerOne.sol (Pip/Act interfaces), MaseerGate.sol, MaseerPrice.sol.
interface IMaseerPip {
    /// @notice The raw oracle NAV price in WAD tGBP-per-wstGBP (un-fee-adjusted).
    function read() external view returns (uint256);
}

interface IMaseerAct {
    /// @notice The ask (mint) price for a given NAV `price`, in WAD tGBP-per-wstGBP.
    function mintcost(uint256 price) external view returns (uint256);

    /// @notice The bid (redeem) price for a given NAV `price`, in WAD tGBP-per-wstGBP (~25bps below ask).
    function burncost(uint256 price) external view returns (uint256);

    /// @notice The redemption cooldown in seconds. MUST be 0 for the sell backstop's redeem to settle
    ///         tGBP atomically within the swap.
    function cooldown() external view returns (uint256);
}
