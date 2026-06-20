// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Iwsgem
/// @notice Minimal interface for a "wrapped gem" (wsgem) atomic wrapper, used by the backstop hook and the
///         direct adapter.
/// @dev wsgem is an ERC20 wrapper over an underlying purchase token it calls the "gem" (exposed via
///      `gem()`). Both tokens use 18 decimals and all prices below are WAD (1e18) quotes of gem-per-wsgem.
///      The concrete deployment (token addresses) is pinned by the deploy script, not by this interface.
interface Iwsgem {
    /// @notice Mint wsgem by depositing gem.
    /// @dev Pulls `amt` gem from msg.sender (requires prior gem approval to this contract) and
    ///      mints `_out = amt * 1e18 / mintcost()` wsgem to msg.sender.
    ///      Reverts if the market is not `mintable()`, if `amt < mintcost()` (dust threshold), if
    ///      `totalSupply + _out > capacity()`, or if msg.sender fails the compliance check.
    /// @param amt Amount of gem to spend (18 decimals).
    /// @return _out Amount of wsgem minted to msg.sender (18 decimals).
    function mint(uint256 amt) external returns (uint256 _out);

    /// @notice Redeem wsgem for gem.
    /// @dev Burns `amt` wsgem from msg.sender. Because this deployment has `cooldown() == 0`, the
    ///      redemption is settled atomically in the same call: gem = `amt * burncost() / 1e18` is
    ///      transferred to msg.sender, but only up to the wrapper's current gem balance (it can
    ///      underpay if the wrapper is short on gem). Reverts if the market is not `burnable()`,
    ///      if `amt < 1e18`, or if msg.sender fails the compliance check.
    /// @param amt Amount of wsgem to redeem (18 decimals).
    /// @return _id The redemption id (NOT the gem amount). Callers must measure the gem actually
    ///         received by balance diff.
    function redeem(uint256 amt) external returns (uint256 _id);

    /// @notice The cost to mint, in WAD gem-per-wsgem (the ask). Ratchets up over time.
    function mintcost() external view returns (uint256);

    /// @notice The value on redeem, in WAD gem-per-wsgem (the bid), ~25bps below `mintcost()`.
    function burncost() external view returns (uint256);

    /// @notice The raw oracle NAV price in WAD gem-per-wsgem (un-fee-adjusted).
    function navprice() external view returns (uint256);

    /// @notice Whether minting is currently open.
    function mintable() external view returns (bool);

    /// @notice Whether redemption is currently open.
    function burnable() external view returns (bool);

    /// @notice The maximum total wsgem supply allowed (18 decimals); mints reverting past it.
    function capacity() external view returns (uint256);

    /// @notice The redemption cooldown in seconds. MUST be 0 for the hook's redeem to settle gem
    ///         atomically in the same call; a non-zero value defers payout and breaks the sell path.
    function cooldown() external view returns (uint256);

    /// @notice Total wsgem supply (18 decimals). Used with `capacity()` to check buy headroom.
    function totalSupply() external view returns (uint256);

    /// @notice Whether `usr` passes the wrapper's compliance gate (i.e. is not banned).
    function canPass(address usr) external view returns (bool);

    /// @notice The underlying purchase token (gem).
    function gem() external view returns (address);

    /// @notice The market-timing/fee feed (`act`). `immutable` in the wrapper, so it is safe to
    ///         cache: `mintcost()`/`burncost()`/`cooldown()` forward to it. See {IAct}.
    function act() external view returns (address);

    /// @notice The oracle NAV price feed. `immutable` in the wrapper, so it is safe to cache:
    ///         `navprice()`/`mintcost()`/`burncost()` read from it. See {IPip}.
    function pip() external view returns (address);
}
