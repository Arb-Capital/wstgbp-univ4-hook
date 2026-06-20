// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WstGBPFixture} from "./WstGBPFixture.sol";
import {WsgemDirectAdapter} from "../../src/adapter/WsgemDirectAdapter.sol";
import {WsgemQuoter} from "../../src/v4/periphery/WsgemQuoter.sol";

/// @title WsgemAdapterForkBase
/// @notice Fork scaffolding for the direct adapter: extends {WstGBPFixture} with a deployed
///         {WsgemDirectAdapter}, a {WsgemQuoter} used as the independent price oracle for parity checks,
///         a seeded test contract, and approve-based swap helpers. The adapter takes ordinary
///         `approve → swap` calls (no v4 pool), so the test contract just approves it like any ERC20 spender.
abstract contract WsgemAdapterForkBase is WstGBPFixture {
    WsgemDirectAdapter adapter;
    WsgemQuoter quoter;

    function setUp() public virtual override {
        super.setUp(); // fork + force the wrapper's markets open

        adapter = new WsgemDirectAdapter(wrapper);
        quoter = new WsgemQuoter(wrapper);

        _seedWsgem(1_000_000 * WAD, 500_000 * WAD);

        IERC20Minimal(GEM).approve(address(adapter), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(adapter), type(uint256).max);
    }

    /// @dev BUY pays gem (mint); SELL pays wsgem (redeem).
    function _tokenIn(bool buy) internal pure returns (address) {
        return buy ? GEM : WSGEM;
    }

    function _adapterIn(bool buy, uint256 amountIn) internal returns (uint256) {
        return adapter.swapExactInput(_tokenIn(buy), amountIn, 0, address(this), block.timestamp);
    }

    function _adapterOut(bool buy, uint256 amountOut, uint256 maxIn) internal returns (uint256) {
        return adapter.swapExactOutput(_tokenIn(buy), amountOut, maxIn, address(this), block.timestamp);
    }

    function _assertAdapterClean() internal view {
        assertEq(_bal(GEM, address(adapter)), 0, "adapter holds no gem");
        assertEq(_bal(WSGEM, address(adapter)), 0, "adapter holds no wsgem");
    }
}
