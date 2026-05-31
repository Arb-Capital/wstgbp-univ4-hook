// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IwstGBP
/// @notice Minimal interface for the wstGBP atomic wrapper (MaseerOne) used by the backstop hook.
/// @dev wstGBP is the "Wren Staked tGBP" ERC20 wrapper deployed at
///      0x57C3571f10767E49C9d7b60feb6c67804783B7aE on Ethereum mainnet. The underlying ("gem")
///      is tGBP (0x27f6c8289550fCE67f6B50BeD1F519966aFE5287). Both tokens use 18 decimals and all
///      prices below are WAD (1e18) quotes of tGBP-per-wstGBP.
///
///      Reference implementation: ../maseer-one/src/MaseerOne.sol
interface IwstGBP {
    /// @notice Mint wstGBP by depositing tGBP.
    /// @dev Pulls `amt` tGBP from msg.sender (requires prior tGBP approval to this contract) and
    ///      mints `_out = amt * 1e18 / mintcost()` wstGBP to msg.sender.
    ///      Reverts if the market is not `mintable()`, if `amt < mintcost()` (dust threshold), if
    ///      `totalSupply + _out > capacity()`, or if msg.sender fails the compliance check.
    /// @param amt Amount of tGBP to spend (18 decimals).
    /// @return _out Amount of wstGBP minted to msg.sender (18 decimals).
    function mint(uint256 amt) external returns (uint256 _out);

    /// @notice Redeem wstGBP for tGBP.
    /// @dev Burns `amt` wstGBP from msg.sender. Because this deployment has `cooldown() == 0`, the
    ///      redemption is settled atomically in the same call: tGBP = `amt * burncost() / 1e18` is
    ///      transferred to msg.sender, but only up to the wrapper's current tGBP balance (it can
    ///      underpay if the wrapper is short on tGBP). Reverts if the market is not `burnable()`,
    ///      if `amt < 1e18`, or if msg.sender fails the compliance check.
    /// @param amt Amount of wstGBP to redeem (18 decimals).
    /// @return _id The redemption id (NOT the tGBP amount). Callers must measure the tGBP actually
    ///         received by balance diff.
    function redeem(uint256 amt) external returns (uint256 _id);

    /// @notice The cost to mint, in WAD tGBP-per-wstGBP (the ask). Ratchets up over time.
    function mintcost() external view returns (uint256);

    /// @notice The value on redeem, in WAD tGBP-per-wstGBP (the bid), ~25bps below `mintcost()`.
    function burncost() external view returns (uint256);

    /// @notice The raw oracle NAV price in WAD tGBP-per-wstGBP (un-fee-adjusted).
    function navprice() external view returns (uint256);

    /// @notice Whether minting is currently open.
    function mintable() external view returns (bool);

    /// @notice Whether redemption is currently open.
    function burnable() external view returns (bool);

    /// @notice The maximum total wstGBP supply allowed (18 decimals); mints reverting past it.
    function capacity() external view returns (uint256);

    /// @notice The redemption cooldown in seconds. MUST be 0 for the hook's redeem to settle tGBP
    ///         atomically in the same call; a non-zero value defers payout and breaks the sell path.
    function cooldown() external view returns (uint256);

    /// @notice Total wstGBP supply (18 decimals). Used with `capacity()` to check buy headroom.
    function totalSupply() external view returns (uint256);

    /// @notice Whether `usr` passes the wrapper's compliance gate (i.e. is not banned).
    function canPass(address usr) external view returns (bool);

    /// @notice The underlying purchase token (tGBP).
    function gem() external view returns (address);
}
