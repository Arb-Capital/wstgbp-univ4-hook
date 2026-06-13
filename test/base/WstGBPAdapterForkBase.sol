// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {MaseerForkBase} from "./MaseerForkBase.sol";
import {WstGBPDirectAdapter} from "../../src/adapter/WstGBPDirectAdapter.sol";
import {WstGBPQuoter} from "../../src/v4/periphery/WstGBPQuoter.sol";

/// @title WstGBPAdapterForkBase
/// @notice Fork scaffolding for the direct adapter: extends {MaseerForkBase} with a deployed
///         {WstGBPDirectAdapter}, a {WstGBPQuoter} used as the independent price oracle for parity checks,
///         a seeded test contract, and approve-based swap helpers. The adapter takes ordinary
///         `approve → swap` calls (no v4 pool), so the test contract just approves it like any ERC20 spender.
abstract contract WstGBPAdapterForkBase is MaseerForkBase {
    WstGBPDirectAdapter adapter;
    WstGBPQuoter quoter;

    function setUp() public virtual override {
        super.setUp(); // fork + force the MaseerGate markets open

        adapter = new WstGBPDirectAdapter(wrapper);
        quoter = new WstGBPQuoter(wrapper);

        _seedWst(1_000_000 * WAD, 500_000 * WAD);

        IERC20Minimal(TGBP).approve(address(adapter), type(uint256).max);
        IERC20Minimal(WST).approve(address(adapter), type(uint256).max);
    }

    /// @dev BUY pays tGBP (mint); SELL pays wstGBP (redeem).
    function _tokenIn(bool buy) internal pure returns (address) {
        return buy ? TGBP : WST;
    }

    function _adapterIn(bool buy, uint256 amountIn) internal returns (uint256) {
        return adapter.swapExactInput(_tokenIn(buy), amountIn, 0, address(this), block.timestamp);
    }

    function _adapterOut(bool buy, uint256 amountOut, uint256 maxIn) internal returns (uint256) {
        return adapter.swapExactOutput(_tokenIn(buy), amountOut, maxIn, address(this), block.timestamp);
    }

    function _assertAdapterClean() internal view {
        assertEq(_bal(TGBP, address(adapter)), 0, "adapter holds no tGBP");
        assertEq(_bal(WST, address(adapter)), 0, "adapter holds no wstGBP");
    }
}
