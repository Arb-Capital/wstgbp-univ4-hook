// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {RpcUrl} from "./base/RpcUrl.sol";
import {UsdcWstGbpHook} from "../src/usdc/UsdcWstGbpHook.sol";
import {FeeMath} from "../src/usdc/lib/FeeMath.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";
import {IAggregatorV3} from "../src/usdc/interfaces/IAggregatorV3.sol";

// Addresses chosen so the mock "USDC" sorts BELOW the mock wrapper — the flipped ordering the real
// wstGBP/USDC pair (wstGBP 0x57C3… < USDC 0xA0b8…) never produces. Etched so ordering is deterministic.
address constant M_USDC = address(uint160(0xA0000));
address constant M_WSGBP = address(uint160(0xB0000));

/// @notice End-to-end fee checks in the FLIPPED ordering (`wstGbpIsCurrency0 == false`: USDC is
///         currency0). The real-pair suite only exercises `wstGbpIsCurrency0 == true`; this proves the
///         direction mapping AND the un-inverted pool-price branch (which carries the new 1e6
///         `USDC_UNIT` constant) adapt: here mint side (wstGBP in) is `zeroForOne == false`. Uses the
///         real (forked) PoolManager with mock tokens etched at addresses we order ourselves; NAV 1e18
///         and a round feed number isolate direction from price.
contract UsdcWstGbpFlippedOrderingTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant USDC_UNIT = 1e6;
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    bytes32 constant PM_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    // GBP $1.25, NAV 1.0 => fair = 1/1.25 = 0.8 wstGBP per USDC.
    uint256 constant FAIR = 0.8e18;

    UsdcWstGbpHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    FlippedMockFeed gbpUsd;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(RpcUrl.resolve(vm));

        vm.etch(M_USDC, address(new MockUsdcToken()).code);
        vm.etch(M_WSGBP, address(new MockWrapperToken()).code);
        assertTrue(M_USDC < M_WSGBP, "test premise: USDC sorts below the wrapper");

        gbpUsd = new FlippedMockFeed();
        gbpUsd.set(1.25e8, block.timestamp);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args =
            abi.encode(PM, IAggregatorV3(address(gbpUsd)), Iwsgem(M_WSGBP), M_USDC, _params(), address(this));
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(UsdcWstGbpHook).creationCode, args);
        hook = new UsdcWstGbpHook{salt: salt}(
            PM, IAggregatorV3(address(gbpUsd)), Iwsgem(M_WSGBP), M_USDC, _params(), address(this)
        );
        assertEq(address(hook), hookAddr, "mined address");

        // The whole point: the constructor resolved the flipped ordering.
        assertFalse(hook.wstGbpIsCurrency0(), "wstGBP is currency1 here");
        assertEq(Currency.unwrap(hook.currency0()), M_USDC);
        assertEq(Currency.unwrap(hook.currency1()), M_WSGBP);

        key = PoolKey({
            currency0: Currency.wrap(M_USDC),
            currency1: Currency.wrap(M_WSGBP),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        // Flipped: raw pool price (currency1 base units per currency0 base units) is
        // wstGBP-wei per USDC-unit = fair · 1e12, i.e. ratioX192 = ((fair << 96) / 1e6) << 96 —
        // the same USDC_UNIT fold the un-inverted OracleLib branch applies in reverse.
        uint160 sqrtP = uint160(_isqrt(((FAIR << 96) / USDC_UNIT) << 96));
        PM.initialize(key, sqrtP);

        swapRouter = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        MockUsdcToken(M_USDC).mint(address(this), 1e13); // 10M mock USDC (6 dec)
        MockUsdcToken(M_WSGBP).mint(address(this), 1e27); // 1B mock wstGBP (18 dec)
        IERC20Minimal(M_USDC).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_USDC).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(swapRouter), type(uint256).max);

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        // ~109k wstGBP + ~136k USDC over ±5580 ticks (spacing 1: no rounding needed).
        lpRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tick - 5580, tickUpper: tick + 5580, liquidityDelta: 5e17, salt: 0}),
            ""
        );
    }

    /// @notice Mint side (wstGBP in) is `zeroForOne == false` in the flipped pool and pays the 30 bps
    ///         base; redeem side (USDC in) is `zeroForOne == true` and pays 5 bps — the exact inverse
    ///         of the canonical pool's zeroForOne mapping, same fee schedule.
    function test_flipped_baseFeeMapping() public {
        // Probe sizes small enough that the first swap's own price impact stays inside the
        // 10 bps threshold band.
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD)); // 1 wstGBP in
        assertEq(mintFee, 3000, "mint side base");

        uint24 redeemFee = _swapAndReadFee(true, -int256(USDC_UNIT)); // 1 USDC in
        assertEq(redeemFee, 500, "redeem side base");
    }

    /// @notice d < 0 (fair above pool — GBP/USD dropped): mint side closes and pays the surcharge —
    ///         in flipped zeroForOne terms, the `false` direction.
    function test_flipped_surchargeDirectionMapping() public {
        gbpUsd.set(1.225e8, block.timestamp); // GBP -2% => fair +~2% => d ~ -20000 ppm
        uint24 mintFee = _swapAndReadFee(false, -int256(100 * WAD));
        // surcharge = min((|d| - 1000) * 0.5, 6000): |d| ~20000 -> 9500 > cap => 6000.
        assertEq(mintFee, 9000, "mint base + cap");
    }

    /// @notice d > 0 (GBP/USD rose, fair fell — the ratchet-analog geometry): redeem side
    ///         (zeroForOne == true here) pays; mint side pays base only.
    function test_flipped_oppositeDeviationPaysRedeemSide() public {
        gbpUsd.set(1.275e8, block.timestamp); // GBP +2% => fair -~2% => d ~ +20400 ppm
        uint24 redeemFee = _swapAndReadFee(true, -int256(25 * USDC_UNIT));
        assertEq(redeemFee, 6500, "redeem base + cap");

        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000, "opener pays base");
    }

    /// @notice The un-inverted pool-price branch: at init the pool price equals fair exactly (up to
    ///         isqrt flooring), so deviation is ~0 and both sides pay base. A wrong USDC_UNIT
    ///         constant in this branch would read fair off by 1e12 and saturate every fee.
    function test_flipped_priceBranchReadsFairAtInit() public {
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000);
        uint24 redeemFee = _swapAndReadFee(true, -int256(USDC_UNIT));
        assertEq(redeemFee, 500);
    }

    // ---------------------------------------------------------------- helpers

    function _params() internal pure returns (FeeMath.FeeParams memory p) {
        p = FeeMath.FeeParams({
            baseFeeMintSide: 3000,
            baseFeeRedeemSide: 500,
            minFee: 200,
            maxFee: 10_000,
            fallbackFee: 3000,
            deviationThresholdPpm: 1000,
            toxicitySlopePpm: 500_000,
            surchargeCapPpm: 6000,
            gbpUsdStalenessSec: 90_000
        });
    }

    function _swapAndReadFee(bool zeroForOne, int256 amountSpecified) internal returns (uint24 fee) {
        vm.recordLogs();
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(PM) && logs[i].topics[0] == PM_SWAP_SIG) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                seen = true;
            }
        }
        assertTrue(seen, "PM Swap observed");
    }

    function _isqrt(uint256 x) internal pure returns (uint256 r) {
        if (x == 0) return 0;
        uint256 xx = x;
        uint256 n;
        while (xx > 1) {
            xx >>= 1;
            ++n;
        }
        r = 1 << (n / 2 + 1);
        for (uint256 i = 0; i < 8; ++i) {
            r = (r + x / r) / 2;
        }
        if (r > x / r) r = x / r;
    }

    receive() external payable {}
}

// --- Mocks (etched; minimal ERC20s) ---

contract MockUsdcToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev 6 like the real USDC — the hook constructor asserts this.
    function decimals() external pure virtual returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

/// @dev The wrapper mock is a token that also answers `navprice()` (all the hook reads off it).
contract MockWrapperToken is MockUsdcToken {
    function decimals() external pure override returns (uint8) {
        return 18;
    }

    function navprice() external pure returns (uint256) {
        return 1e18;
    }
}

contract FlippedMockFeed {
    int256 public answer;
    uint256 public updatedAt;

    function set(int256 a, uint256 u) external {
        answer = a;
        updatedAt = u;
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
