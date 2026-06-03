// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IwstGBP} from "../interfaces/IwstGBP.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title WstGBPQuoter
/// @notice Exact, gas-free quotes for the tGBP/wstGBP backstop pool.
/// @dev The backstop's price is the wstGBP wrapper's oracle price (`mintcost()` for buys,
///      `burncost()` for sells) — it does not depend on pool state — so a quote is a pure view that
///      mirrors `WstGBPBackstopHook._beforeSwap`'s arithmetic exactly (same `FullMath` rounding).
///      This sidesteps the stock v4 `Quoter`, which is swap-first and reverts on this hook.
///
///      Pool convention: currency0 = tGBP, currency1 = wstGBP. `zeroForOne == true` is a BUY of
///      wstGBP (pay tGBP), `false` is a SELL.
///
///      Quotes reflect the wrapper's price at the current block; the live price may move (NAV
///      accrues), so integrators should still pass slippage bounds on execution.
contract WstGBPQuoter {
    uint256 internal constant WAD = 1e18;

    IwstGBP public immutable wrapper;
    address public immutable tgbp;

    constructor(IwstGBP _wrapper) {
        wrapper = _wrapper;
        tgbp = _wrapper.gem();
    }

    // -----------------------------------------------------------------------
    // Pure price quotes (mirror the hook exactly)
    // -----------------------------------------------------------------------

    /// @notice Output for an exact-input swap.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountIn The exact input amount (tGBP for a buy, wstGBP for a sell).
    /// @return amountOut The output amount (wstGBP for a buy, tGBP for a sell).
    function quoteExactInput(bool zeroForOne, uint256 amountIn) public view returns (uint256 amountOut) {
        amountOut = zeroForOne
            ? FullMath.mulDiv(amountIn, WAD, wrapper.mintcost())  // wstGBP out = tGBP in * 1e18 / mintcost
            : FullMath.mulDiv(amountIn, wrapper.burncost(), WAD); // tGBP out = wstGBP in * burncost / 1e18
    }

    /// @notice Input required for an exact-output swap (rounded up, matching the hook).
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountOut The exact output amount (wstGBP for a buy, tGBP for a sell).
    /// @return amountIn The input the caller must provide (tGBP for a buy, wstGBP for a sell).
    function quoteExactOutput(bool zeroForOne, uint256 amountOut) public view returns (uint256 amountIn) {
        amountIn = zeroForOne
            ? FullMath.mulDivRoundingUp(amountOut, wrapper.mintcost(), WAD)  // tGBP in = ceil(wstGBP out * mintcost / 1e18)
            : FullMath.mulDivRoundingUp(amountOut, WAD, wrapper.burncost()); // wstGBP in = ceil(tGBP out * 1e18 / burncost)
    }

    // -----------------------------------------------------------------------
    // Full preview: amounts + whether it would execute right now
    // -----------------------------------------------------------------------

    /// @notice Quote a swap using the same `amountSpecified` convention as `PoolManager.swap`, and
    ///         report whether it would execute against the live wrapper right now.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountSpecified Negative for exact-input, positive for exact-output.
    /// @return amountIn Input the caller pays.
    /// @return amountOut Output the caller receives.
    /// @return executable True if a swap of this size would succeed at the current block.
    /// @return reason Empty if executable, otherwise a short human-readable cause.
    function previewSwap(bool zeroForOne, int256 amountSpecified)
        external
        view
        returns (uint256 amountIn, uint256 amountOut, bool executable, string memory reason)
    {
        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = quoteExactInput(zeroForOne, amountIn);
        } else {
            amountOut = uint256(amountSpecified);
            amountIn = quoteExactOutput(zeroForOne, amountOut);
        }
        (executable, reason) = _check(zeroForOne, amountIn);
    }

    /// @dev Mirrors the revert conditions of `wstGBP.mint`/`redeem` and the hook's underfunded guard.
    function _check(bool zeroForOne, uint256 amountIn) internal view returns (bool executable, string memory reason) {
        if (zeroForOne) {
            // BUY: mint wstGBP with `amountIn` tGBP.
            uint256 mc = wrapper.mintcost();
            if (!wrapper.mintable()) return (false, "mint market closed");
            if (amountIn < mc) return (false, "below mint dust threshold");
            // `wrapper.mint(amountIn)` mints `amountIn*1e18/mintcost`, which for an exact-output buy is
            // >= the requested `amountOut` (the input was rounded up). Check capacity against that
            // minted amount, not `amountOut`, so the preview can't pass while `wrapper.mint` reverts.
            uint256 minted = FullMath.mulDiv(amountIn, WAD, mc);
            if (wrapper.totalSupply() + minted > wrapper.capacity()) return (false, "exceeds capacity");
        } else {
            // SELL: redeem `amountIn` wstGBP for tGBP.
            if (!wrapper.burnable()) return (false, "burn market closed");
            // The hook's redeem only settles atomically when cooldown is 0; otherwise the sell would
            // burn wstGBP without paying out, so the hook reverts `RedeemUnderpaid`.
            if (wrapper.cooldown() != 0) return (false, "redeem cooldown active");
            if (amountIn < WAD) return (false, "below redeem minimum");
            uint256 claim = FullMath.mulDiv(amountIn, wrapper.burncost(), WAD);
            if (IERC20Minimal(tgbp).balanceOf(address(wrapper)) < claim) return (false, "wrapper underfunded");
        }
        return (true, "");
    }
}
