// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IwstGBP} from "../../core/interfaces/IwstGBP.sol";
import {IMaseerAct, IMaseerPip} from "../../core/interfaces/IMaseerFeeds.sol";
import {WstGBPWrap} from "../../core/WstGBPWrap.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

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
    /// @dev The wrapper's two immutable price feeds, cached so the quoter can read the backstop price
    ///      directly (act.mintcost(pip.read())) and skip the wrapper's dispatch hop — byte-identical to
    ///      `wrapper.mintcost()`/`burncost()`/`cooldown()`, matching `WstGBPBackstopHook`. See {IMaseerFeeds}.
    IMaseerAct public immutable act;
    IMaseerPip public immutable pip;

    constructor(IwstGBP _wrapper) {
        wrapper = _wrapper;
        tgbp = _wrapper.gem();
        act = IMaseerAct(_wrapper.act());
        pip = IMaseerPip(_wrapper.pip());
    }

    // -----------------------------------------------------------------------
    // Pure price quotes (mirror the hook exactly)
    // -----------------------------------------------------------------------

    /// @notice Output for an exact-input swap.
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountIn The exact input amount (tGBP for a buy, wstGBP for a sell).
    /// @return amountOut The output amount (wstGBP for a buy, tGBP for a sell).
    function quoteExactInput(bool zeroForOne, uint256 amountIn) public view returns (uint256 amountOut) {
        amountOut = _quoteIn(zeroForOne, amountIn, _price(zeroForOne));
    }

    /// @notice Input required for an exact-output swap (rounded up, matching the hook).
    /// @param zeroForOne True to buy wstGBP with tGBP, false to sell wstGBP for tGBP.
    /// @param amountOut The exact output amount (wstGBP for a buy, tGBP for a sell).
    /// @return amountIn The input the caller must provide (tGBP for a buy, wstGBP for a sell).
    function quoteExactOutput(bool zeroForOne, uint256 amountOut) public view returns (uint256 amountIn) {
        amountIn = _quoteOut(zeroForOne, amountOut, _price(zeroForOne));
    }

    /// @dev Backstop price read directly off the wrapper's immutable feeds — mintcost (ask) for a buy,
    ///      burncost (bid) for a sell. Byte-identical to `wrapper.mintcost()`/`burncost()`, one hop cheaper
    ///      (one `pip.read()` + one spread call). Returns 0 when the oracle is paused (`pip.read() == 0`).
    function _price(bool zeroForOne) internal view returns (uint256) {
        return WstGBPWrap.price(act, pip, zeroForOne);
    }

    /// @dev Exact-input math at a given backstop `price` (shared by the public quote and `previewSwap`).
    function _quoteIn(bool zeroForOne, uint256 amountIn, uint256 price) internal pure returns (uint256) {
        return WstGBPWrap.quoteIn(zeroForOne, amountIn, price);
    }

    /// @dev Exact-output math (rounded up, matching the hook) at a given backstop `price`.
    function _quoteOut(bool zeroForOne, uint256 amountOut, uint256 price) internal pure returns (uint256) {
        return WstGBPWrap.quoteOut(zeroForOne, amountOut, price);
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
        // A paused oracle reads as a zero NAV (`MaseerPrice.pause()` pokes 0), so `mintcost()`/`burncost()`
        // are 0 and the quote arithmetic below would divide by zero. Report it as non-executable like every
        // other gate instead of reverting, so off-chain callers always get a clean (executable, reason).
        // Read the price once here and reuse it for the quote and the executability check below.
        uint256 price = _price(zeroForOne);
        if (price == 0) return (0, 0, false, "oracle paused");

        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = _quoteIn(zeroForOne, amountIn, price);
        } else {
            amountOut = uint256(amountSpecified);
            amountIn = _quoteOut(zeroForOne, amountOut, price);
        }
        (executable, reason) = _check(zeroForOne, amountIn, price);
    }

    /// @dev Mirrors the revert conditions of `wstGBP.mint`/`redeem` and the hook's underfunded guard. The
    ///      paused-oracle case (zero price) is handled by `previewSwap` before this runs, so `price` is
    ///      non-zero here; `price` is the backstop ask (mintcost) for a buy and the bid (burncost) for a
    ///      sell, already read once by the caller. The `mintable`/`burnable`/`totalSupply`/`capacity` gates
    ///      are wrapper state (not on the `act`/`pip` feeds), so they stay as wrapper reads.
    function _check(bool zeroForOne, uint256 amountIn, uint256 price)
        internal
        view
        returns (bool executable, string memory reason)
    {
        if (zeroForOne) {
            // BUY: mint wstGBP with `amountIn` tGBP. `price` == mintcost.
            if (!wrapper.mintable()) return (false, "mint market closed");
            if (amountIn < price) return (false, "below mint dust threshold");
            // `wrapper.mint(amountIn)` mints `amountIn*1e18/mintcost`, which for an exact-output buy is
            // >= the requested `amountOut` (the input was rounded up). Check capacity against that
            // minted amount, not `amountOut`, so the preview can't pass while `wrapper.mint` reverts.
            uint256 minted = WstGBPWrap.quoteIn(true, amountIn, price);
            if (wrapper.totalSupply() + minted > wrapper.capacity()) return (false, "exceeds capacity");
        } else {
            // SELL: redeem `amountIn` wstGBP for tGBP. `price` == burncost.
            if (!wrapper.burnable()) return (false, "burn market closed");
            // The hook's redeem only settles atomically when cooldown is 0; otherwise the sell would
            // burn wstGBP without paying out, so the hook reverts `RedeemUnderpaid`.
            if (act.cooldown() != 0) return (false, "redeem cooldown active");
            if (amountIn < WAD) return (false, "below redeem minimum");
            uint256 claim = WstGBPWrap.quoteIn(false, amountIn, price);
            if (IERC20Minimal(tgbp).balanceOf(address(wrapper)) < claim) return (false, "wrapper underfunded");
        }
        return (true, "");
    }
}
