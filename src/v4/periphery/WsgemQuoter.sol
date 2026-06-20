// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Iwsgem} from "../../core/interfaces/Iwsgem.sol";
import {IAct, IPip} from "../../core/interfaces/IFeeds.sol";
import {WsgemWrap} from "../../core/WsgemWrap.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title WsgemQuoter
/// @notice Exact, gas-free quotes for the gem/wsgem backstop pool.
/// @dev The backstop's price is the wsgem wrapper's oracle price (`mintcost()` for buys,
///      `burncost()` for sells) — it does not depend on pool state — so a quote is a pure view that
///      mirrors `WsgemBackstopHook._beforeSwap`'s arithmetic exactly (same `FullMath` rounding).
///      This sidesteps the stock v4 `Quoter`, which is swap-first and reverts on this hook.
///
///      The pool's two currencies are gem and wsgem in v4's canonical sorted order; `zeroForOne` follows
///      `PoolManager.swap` (pay currency0). Whether that is a BUY of wsgem (mint) or a SELL (redeem)
///      depends on the pair's address ordering — the quoter maps it via `buy == (zeroForOne == gemIsZero)`,
///      mirroring the hook.
///
///      Quotes reflect the wrapper's price at the current block; the live price may move (NAV
///      accrues), so integrators should still pass slippage bounds on execution.
contract WsgemQuoter {
    uint256 internal constant WAD = 1e18;

    Iwsgem public immutable wrapper;
    address public immutable gem;
    /// @dev True when `gem` is currency0 (gem < wsgem). A swap is a BUY iff `zeroForOne == gemIsZero`.
    bool public immutable gemIsZero;
    /// @dev The wrapper's two immutable price feeds, cached so the quoter can read the backstop price
    ///      directly (act.mintcost(pip.read())) and skip the wrapper's dispatch hop — byte-identical to
    ///      `wrapper.mintcost()`/`burncost()`/`cooldown()`, matching `WsgemBackstopHook`. See {IFeeds}.
    IAct public immutable act;
    IPip public immutable pip;

    error IdenticalCurrencies();

    constructor(Iwsgem _wrapper) {
        wrapper = _wrapper;
        address _gem = _wrapper.gem();
        gem = _gem;
        // A wrapper that names itself as its own underlying would make `gemIsZero`/direction ambiguous;
        // reject it (mirrors the hook's same-currency guard).
        if (_gem == address(_wrapper)) revert IdenticalCurrencies();
        gemIsZero = _gem < address(_wrapper);
        act = IAct(_wrapper.act());
        pip = IPip(_wrapper.pip());
    }

    // -----------------------------------------------------------------------
    // Pure price quotes (mirror the hook exactly)
    // -----------------------------------------------------------------------

    /// @notice Output for an exact-input swap.
    /// @param zeroForOne Swap direction per `PoolManager.swap` (pay currency0); a BUY of wsgem iff it
    ///        equals `gemIsZero`, otherwise a SELL.
    /// @param amountIn The exact input amount (gem for a buy, wsgem for a sell).
    /// @return amountOut The output amount (wsgem for a buy, gem for a sell).
    function quoteExactInput(bool zeroForOne, uint256 amountIn) public view returns (uint256 amountOut) {
        bool buy = zeroForOne == gemIsZero;
        amountOut = _quoteIn(buy, amountIn, _price(buy));
    }

    /// @notice Input required for an exact-output swap (rounded up, matching the hook).
    /// @param zeroForOne Swap direction per `PoolManager.swap` (pay currency0); a BUY of wsgem iff it
    ///        equals `gemIsZero`, otherwise a SELL.
    /// @param amountOut The exact output amount (wsgem for a buy, gem for a sell).
    /// @return amountIn The input the caller must provide (gem for a buy, wsgem for a sell).
    function quoteExactOutput(bool zeroForOne, uint256 amountOut) public view returns (uint256 amountIn) {
        bool buy = zeroForOne == gemIsZero;
        amountIn = _quoteOut(buy, amountOut, _price(buy));
    }

    /// @dev Backstop price read directly off the wrapper's immutable feeds — mintcost (ask) for a buy,
    ///      burncost (bid) for a sell. Byte-identical to `wrapper.mintcost()`/`burncost()`, one hop cheaper
    ///      (one `pip.read()` + one spread call). Returns 0 when the oracle is paused (`pip.read() == 0`).
    function _price(bool buy) internal view returns (uint256) {
        return WsgemWrap.price(act, pip, buy);
    }

    /// @dev Exact-input math at a given backstop `price` (shared by the public quote and `previewSwap`).
    function _quoteIn(bool buy, uint256 amountIn, uint256 price) internal pure returns (uint256) {
        return WsgemWrap.quoteIn(buy, amountIn, price);
    }

    /// @dev Exact-output math (rounded up, matching the hook) at a given backstop `price`.
    function _quoteOut(bool buy, uint256 amountOut, uint256 price) internal pure returns (uint256) {
        return WsgemWrap.quoteOut(buy, amountOut, price);
    }

    // -----------------------------------------------------------------------
    // Full preview: amounts + whether it would execute right now
    // -----------------------------------------------------------------------

    /// @notice Quote a swap using the same `amountSpecified` convention as `PoolManager.swap`, and
    ///         report whether it would execute against the live wrapper right now.
    /// @param zeroForOne Swap direction per `PoolManager.swap` (pay currency0); a BUY of wsgem iff it
    ///        equals `gemIsZero`, otherwise a SELL.
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
        // A paused oracle reads as a zero NAV (the oracle feed's pause pokes 0), so `mintcost()`/`burncost()`
        // are 0 and the quote arithmetic below would divide by zero. Report it as non-executable like every
        // other gate instead of reverting, so off-chain callers always get a clean (executable, reason).
        // Read the price once here and reuse it for the quote and the executability check below.
        bool buy = zeroForOne == gemIsZero;
        uint256 price = _price(buy);
        if (price == 0) return (0, 0, false, "oracle paused");

        if (amountSpecified < 0) {
            amountIn = uint256(-amountSpecified);
            amountOut = _quoteIn(buy, amountIn, price);
        } else {
            amountOut = uint256(amountSpecified);
            amountIn = _quoteOut(buy, amountOut, price);
        }
        (executable, reason) = _check(buy, amountIn, price);
    }

    /// @dev Mirrors the revert conditions of `wsgem.mint`/`redeem` and the hook's underfunded guard. The
    ///      paused-oracle case (zero price) is handled by `previewSwap` before this runs, so `price` is
    ///      non-zero here; `price` is the backstop ask (mintcost) for a buy and the bid (burncost) for a
    ///      sell, already read once by the caller. The `mintable`/`burnable`/`totalSupply`/`capacity` gates
    ///      are wrapper state (not on the `act`/`pip` feeds), so they stay as wrapper reads.
    function _check(bool buy, uint256 amountIn, uint256 price)
        internal
        view
        returns (bool executable, string memory reason)
    {
        if (buy) {
            // BUY: mint wsgem with `amountIn` gem. `price` == mintcost.
            if (!wrapper.mintable()) return (false, "mint market closed");
            if (amountIn < price) return (false, "below mint dust threshold");
            // `wrapper.mint(amountIn)` mints `amountIn*1e18/mintcost`, which for an exact-output buy is
            // >= the requested `amountOut` (the input was rounded up). Check capacity against that
            // minted amount, not `amountOut`, so the preview can't pass while `wrapper.mint` reverts.
            uint256 minted = WsgemWrap.quoteIn(true, amountIn, price);
            if (wrapper.totalSupply() + minted > wrapper.capacity()) return (false, "exceeds capacity");
        } else {
            // SELL: redeem `amountIn` wsgem for gem. `price` == burncost.
            if (!wrapper.burnable()) return (false, "burn market closed");
            // The hook's redeem only settles atomically when cooldown is 0; otherwise the sell would
            // burn wsgem without paying out, so the hook reverts `RedeemUnderpaid`.
            if (act.cooldown() != 0) return (false, "redeem cooldown active");
            if (amountIn < WAD) return (false, "below redeem minimum");
            uint256 claim = WsgemWrap.quoteIn(false, amountIn, price);
            if (IERC20Minimal(gem).balanceOf(address(wrapper)) < claim) return (false, "wrapper underfunded");
        }
        return (true, "");
    }
}
