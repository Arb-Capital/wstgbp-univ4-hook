// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WsgemForkBase} from "./base/WsgemForkBase.sol";
import {WsgemDirectAdapter} from "../src/adapter/WsgemDirectAdapter.sol";

/// @title WsgemGasComparisonTest
/// @notice Swapper-economics gas comparison. The backstop prices a v4 pool swap off the wrapper's oracle, so
///         a pool swap delivers the SAME price as calling `wstGBP.mint`/`redeem` directly (or via the
///         inventory-free {WsgemDirectAdapter}). For a swapper who already holds the input token, the only
///         thing the pool route adds over a direct mint/redeem is gas. These tests quantify that premium
///         (logged under `-vv`) and assert the pool route is strictly the most expensive of the three — a
///         regression guard for "the pool is the dearest way to get a price you can get for less elsewhere".
contract WsgemGasComparisonTest is WsgemForkBase {
    WsgemDirectAdapter adapter;

    function setUp() public override {
        super.setUp();
        adapter = new WsgemDirectAdapter(wrapper);
        IERC20Minimal(GEM).approve(address(adapter), type(uint256).max);
        IERC20Minimal(WSGEM).approve(address(adapter), type(uint256).max);
        // Fund every redeem/sell path generously so funding never confounds the gas measurement.
        deal(GEM, WSGEM, 10_000_000 * WAD);
    }

    function test_gasComparison_buy() public {
        uint256 amt = 100 * WAD;

        // Warm each path once so the measured numbers reflect a repeat swapper's hot path (no cold-SLOAD noise).
        _swapIn(true, amt);
        wrapper.mint(amt);
        adapter.swapExactInput(GEM, amt, 0, address(this), block.timestamp);

        uint256 g;
        g = gasleft();
        _swapIn(true, amt);
        uint256 poolGas = g - gasleft();

        g = gasleft();
        wrapper.mint(amt);
        uint256 directGas = g - gasleft();

        g = gasleft();
        adapter.swapExactInput(GEM, amt, 0, address(this), block.timestamp);
        uint256 adapterGas = g - gasleft();

        emit log_named_uint("buy: pool route gas", poolGas);
        emit log_named_uint("buy: adapter gas   ", adapterGas);
        emit log_named_uint("buy: direct mint   ", directGas);

        assertGt(poolGas, directGas, "pool route costs more gas than a direct mint for the same price");
        assertGt(adapterGas, directGas, "adapter costs more gas than a direct mint for the same price");
        assertGt(poolGas, adapterGas, "pool route is the dearest of the three (router + PoolManager overhead)");
    }

    function test_gasComparison_sell() public {
        uint256 amt = 100 * WAD;

        // Warm each path once. `wrapper.redeem` returns a redemption id (not the gem amount); we ignore it —
        // only the gas of the call matters here.
        _swapIn(false, amt);
        wrapper.redeem(amt);
        adapter.swapExactInput(WSGEM, amt, 0, address(this), block.timestamp);

        uint256 g;
        g = gasleft();
        _swapIn(false, amt);
        uint256 poolGas = g - gasleft();

        g = gasleft();
        wrapper.redeem(amt);
        uint256 directGas = g - gasleft();

        g = gasleft();
        adapter.swapExactInput(WSGEM, amt, 0, address(this), block.timestamp);
        uint256 adapterGas = g - gasleft();

        emit log_named_uint("sell: pool route gas", poolGas);
        emit log_named_uint("sell: adapter gas   ", adapterGas);
        emit log_named_uint("sell: direct redeem ", directGas);

        assertGt(poolGas, directGas, "pool route costs more gas than a direct redeem for the same price");
        assertGt(adapterGas, directGas, "adapter costs more gas than a direct redeem for the same price");
        assertGt(poolGas, adapterGas, "pool route is the dearest of the three (router + PoolManager overhead)");
    }
}
