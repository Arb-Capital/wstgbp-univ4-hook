// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Iwsgem} from "./interfaces/Iwsgem.sol";
import {IAct, IPip} from "./interfaces/IFeeds.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title WsgemWrap
/// @notice Shared, venue-agnostic core for pricing and settling swaps through the wsgem wrapper's atomic
///         mint/redeem at the protocol's own oracle prices. Both the Uniswap v4 backstop hook
///         (`src/v4/WsgemBackstopHook.sol`) and the direct aggregator/solver adapter
///         (`src/adapter/WsgemDirectAdapter.sol`) route their price math and redeem safety through here,
///         so a pricing or redeem-safety change happens in ONE place and can never drift between venues.
/// @dev Every function is `internal`, so the library is embedded into each caller (no linking, no
///      delegatecall, gas/behaviour identical to inlining). Prices are read directly off the wrapper's
///      two immutable feeds — `act.mintcost(pip.read())` (ask) / `act.burncost(pip.read())` (bid) — which
///      is byte-identical to `wsgem.mintcost()`/`burncost()` because `mint`/`redeem` read the same feeds.
///      The `FullMath` rounding here is the single source the venues' parity tests pin their execution to.
library WsgemWrap {
    uint256 internal constant WAD = 1e18;

    /// @notice Backstop price off the wrapper's immutable feeds: mintcost (ask) for a buy, burncost (bid)
    ///         for a sell. Returns 0 when the oracle is paused (`pip.read() == 0`), letting callers report
    ///         it as non-executable instead of dividing by zero.
    function price(IAct act, IPip pip, bool buy) internal view returns (uint256) {
        uint256 nav = pip.read();
        return buy ? act.mintcost(nav) : act.burncost(nav);
    }

    /// @notice Output for an exact-input swap at backstop price `p`.
    function quoteIn(bool buy, uint256 amountIn, uint256 p) internal pure returns (uint256) {
        return buy
            ? FullMath.mulDiv(amountIn, WAD, p)  // wsgem out = gem in * 1e18 / mintcost
            : FullMath.mulDiv(amountIn, p, WAD); // gem out  = wsgem in * burncost / 1e18
    }

    /// @notice Input required for an exact-output swap at backstop price `p`, rounded up (the wrapper may
    ///         over-deliver by price-bounded dust; never under-deliver).
    function quoteOut(bool buy, uint256 amountOut, uint256 p) internal pure returns (uint256) {
        return buy
            ? FullMath.mulDivRoundingUp(amountOut, p, WAD)  // gem in  = ceil(wsgem out * mintcost / 1e18)
            : FullMath.mulDivRoundingUp(amountOut, WAD, p); // wsgem in = ceil(gem out * 1e18 / burncost)
    }

    /// @notice Redeem `wIn` wsgem and return the gem actually received, measured by balance diff because
    ///         `wsgem.redeem` returns a redemption id (not an amount) and can underpay if the wrapper is
    ///         short on gem. The caller must already hold the `wIn` wsgem and must assert the received
    ///         amount covers its claim (a cooldown change can otherwise defer/zero the payout).
    /// @dev Burns from `address(this)` (the calling venue), so no approval is needed for the redeem.
    function redeem(Iwsgem wrapper, address gem, uint256 wIn) internal returns (uint256 received) {
        uint256 before = IERC20Minimal(gem).balanceOf(address(this));
        wrapper.redeem(wIn);
        received = IERC20Minimal(gem).balanceOf(address(this)) - before;
    }

    /// @notice ERC20 transfer tolerant of non-standard (no-boolean-return) tokens. Returns success rather
    ///         than reverting, so each venue keeps its own error identity (`revert TransferFailed()`).
    function transfer(address token, address to, uint256 amount) internal returns (bool ok) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 0x04), to)
            mstore(add(ptr, 0x24), amount)

            ok := call(gas(), token, 0, ptr, 0x44, 0, 0x20)
            if ok {
                switch returndatasize()
                case 0 { ok := 1 }
                case 0x20 {
                    returndatacopy(ptr, 0, 0x20)
                    ok := iszero(iszero(mload(ptr)))
                }
                default { ok := 0 }
            }
        }
    }
}
