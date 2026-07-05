// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {UsdcWstGbpForkBase} from "./base/UsdcWstGbpForkBase.sol";

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice Pins the Uniswap-UI funding path: the treasury Safe funds POL through the CANONICAL
///         PositionManager (mint / collect / exit as v4 position NFTs) — no scripts, no compounder.
///         The hook has no liquidity callbacks, so PosM positions must work exactly like any vanilla
///         v4 pool; these tests execute the same call shape the web app produces (Permit2 allowance
///         + `modifyLiquidities` action batches) against the real mainnet PosM.
contract UsdcWstGbpPositionManagerTest is UsdcWstGbpForkBase {
    using StateLibrary for IPoolManager;

    IPositionManager constant POSM = IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IAllowanceTransfer constant PERMIT2_ALLOWANCE = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    function setUp() public override {
        super.setUp();
        // The UI's approval flow: ERC-20 approve to Permit2 once, then a Permit2 allowance to PosM.
        IERC20Minimal(WSGEM).approve(address(PERMIT2_ALLOWANCE), type(uint256).max);
        IERC20Minimal(USDC).approve(address(PERMIT2_ALLOWANCE), type(uint256).max);
        PERMIT2_ALLOWANCE.approve(WSGEM, address(POSM), type(uint160).max, type(uint48).max);
        PERMIT2_ALLOWANCE.approve(USDC, address(POSM), type(uint160).max, type(uint48).max);
    }

    function _mint(int24 lower, int24 upper, uint256 liquidity) internal returns (uint256 tokenId) {
        tokenId = POSM.nextTokenId();
        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(key, lower, upper, liquidity, type(uint128).max, type(uint128).max, address(this), "");
        params[1] = abi.encode(key.currency0, key.currency1);
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function _decreaseAndTake(uint256 tokenId, uint256 liquidity) internal {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, liquidity, uint128(0), uint128(0), "");
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        POSM.modifyLiquidities(abi.encode(actions, params), block.timestamp + 60);
    }

    function _posmPositionLiquidity(uint256 tokenId, int24 lower, int24 upper) internal view returns (uint128) {
        // PosM holds positions keyed (posm, range, salt = tokenId).
        return PM.getPositionLiquidity(
            key.toId(), Position.calculatePositionKey(address(POSM), lower, upper, bytes32(tokenId))
        );
    }

    /// @notice The full treasury lifecycle, UI-shaped: mint -> fees accrue -> collect -> exit.
    function test_uiLifecycle_mintCollectExit() public {
        uint256 tokenId = _mint(tickLower, tickUpper, 5e16);
        assertEq(IERC721Minimal(address(POSM)).ownerOf(tokenId), address(this), "position NFT held by the funder");
        assertEq(_posmPositionLiquidity(tokenId, tickLower, tickUpper), 5e16, "liquidity live in the pool");

        // The hook's fee schedule is completely undisturbed by PosM liquidity: base fees at ~zero
        // deviation, observed from the PM's own Swap event.
        SwapObservation memory mint = _swapAndObserve(true, -int256(100 * WAD));
        assertEq(mint.pmFee, 3000, "mint-side base");
        SwapObservation memory redeem = _swapAndObserve(false, -int256(100 * USDC_UNIT));
        assertEq(redeem.pmFee, 500, "redeem-side base");

        // Collect fees (the UI's "collect" button): DECREASE_LIQUIDITY(0) + TAKE_PAIR.
        uint256 wsgBefore = _bal(WSGEM, address(this));
        uint256 usdcBefore = _bal(USDC, address(this));
        _decreaseAndTake(tokenId, 0);
        uint256 collected0 = _bal(WSGEM, address(this)) - wsgBefore;
        uint256 collected1 = _bal(USDC, address(this)) - usdcBefore;
        assertTrue(collected0 > 0 || collected1 > 0, "fees collected");
        assertEq(_posmPositionLiquidity(tokenId, tickLower, tickUpper), 5e16, "principal untouched by collect");

        // Full exit (the UI's "remove liquidity"): principal + any residual fees back to the wallet.
        wsgBefore = _bal(WSGEM, address(this));
        usdcBefore = _bal(USDC, address(this));
        _decreaseAndTake(tokenId, 5e16);
        assertEq(_posmPositionLiquidity(tokenId, tickLower, tickUpper), 0, "position emptied");
        uint256 fair = _fairWad();
        uint256 recoveredValueWsg =
            (_bal(WSGEM, address(this)) - wsgBefore) + (_bal(USDC, address(this)) - usdcBefore) * fair / USDC_UNIT;
        assertGt(recoveredValueWsg, 0, "principal recovered");
    }

    /// @notice A custom TIGHT bracket entered as min/max prices in the UI — the shape this venue's
    ///         POL will actually use (near-stable pair: a band of a few % around fair, spacing-1
    ///         placement; the concrete production bracket is chosen at funding time per DEPLOY.md).
    ///         ±150 ticks ≈ ±1.5%: covers ~1.5 years of NAV ratchet drift plus intraday cable noise.
    function test_uiCustomTightBracketMints() public {
        (, int24 tickNow,,) = _slot0();
        int24 lower = tickNow - 150;
        int24 upper = tickNow + 150;
        uint256 tokenId = _mint(lower, upper, 5e18);
        assertEq(_posmPositionLiquidity(tokenId, lower, upper), 5e18, "bracket position live");

        // The current tick sits inside the bracket, so it earns immediately: a swap pays fees into it.
        assertTrue(lower < tickNow && tickNow < upper, "current price inside the bracket");
        SwapObservation memory o = _swapAndObserve(true, -int256(10 * WAD));
        assertEq(o.pmFee, 3000, "fee schedule unchanged for custom ranges");
    }
}
