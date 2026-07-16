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
import {XautWstGbpHook} from "../src/xaut/XautWstGbpHook.sol";
import {FeeMath} from "../src/xaut/lib/FeeMath.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";
import {IAggregatorV3} from "../src/xaut/interfaces/IAggregatorV3.sol";

// Addresses chosen so the mock "XAUT" sorts BELOW the mock wrapper — the flipped ordering the real
// XAUT/wstGBP pair (wstGBP 0x57C3… < XAUT 0x6874…) never produces. Etched so ordering is deterministic.
address constant M_XAUT = address(uint160(0xA0000));
address constant M_WSGBP = address(uint160(0xB0000));

/// @notice End-to-end fee checks in the FLIPPED ordering (`wstGbpIsCurrency0 == false`: XAUT is
///         currency0). The real-pair suite only exercises `wstGbpIsCurrency0 == true`; this proves the
///         direction mapping AND the un-inverted pool-price branch (which carries the 1e6 `XAUT_UNIT`
///         constant) adapt: here mint side (wstGBP in) is `zeroForOne == false`. Uses the real
///         (forked) PoolManager with mock tokens etched at addresses we order ourselves; NAV 1e18
///         and round feed numbers isolate direction from price.
contract XautWstGbpFlippedOrderingTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant XAUT_UNIT = 1e6;
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    bytes32 constant PM_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    // Gold $2500, GBP $1.25, NAV 1.0 => fair = 2500/1.25 = 2000 wstGBP per XAUT.
    uint256 constant FAIR = 2000e18;

    XautWstGbpHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    FlippedMockFeed xauUsd;
    FlippedMockFeed gbpUsd;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(RpcUrl.resolve(vm));

        vm.etch(M_XAUT, address(new MockXautToken()).code);
        vm.etch(M_WSGBP, address(new MockWrapperToken()).code);
        assertTrue(M_XAUT < M_WSGBP, "test premise: XAUT sorts below the wrapper");

        xauUsd = new FlippedMockFeed();
        gbpUsd = new FlippedMockFeed();
        xauUsd.set(2500e8, block.timestamp);
        gbpUsd.set(1.25e8, block.timestamp);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(
            PM,
            IAggregatorV3(address(xauUsd)),
            IAggregatorV3(address(gbpUsd)),
            Iwsgem(M_WSGBP),
            M_XAUT,
            _params(),
            address(this)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(XautWstGbpHook).creationCode, args);
        hook = new XautWstGbpHook{salt: salt}(
            PM,
            IAggregatorV3(address(xauUsd)),
            IAggregatorV3(address(gbpUsd)),
            Iwsgem(M_WSGBP),
            M_XAUT,
            _params(),
            address(this)
        );
        assertEq(address(hook), hookAddr, "mined address");

        // The whole point: the constructor resolved the flipped ordering.
        assertFalse(hook.wstGbpIsCurrency0(), "wstGBP is currency1 here");
        assertEq(Currency.unwrap(hook.currency0()), M_XAUT);
        assertEq(Currency.unwrap(hook.currency1()), M_WSGBP);

        key = PoolKey({
            currency0: Currency.wrap(M_XAUT),
            currency1: Currency.wrap(M_WSGBP),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // Flipped: raw pool price (currency1 base units per currency0 base units) is
        // wstGBP-wei per XAUT-unit = fair · 1e12, i.e. ratioX192 = ((fair << 96) / 1e6) << 96 —
        // the same XAUT_UNIT fold the un-inverted OracleLib branch applies in reverse.
        uint160 sqrtP = uint160(_isqrt(((FAIR << 96) / XAUT_UNIT) << 96));
        PM.initialize(key, sqrtP);

        swapRouter = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        MockXautToken(M_XAUT).mint(address(this), 1e13); // 10M mock XAUT (6 dec)
        MockXautToken(M_WSGBP).mint(address(this), 1e27); // 1B mock wstGBP (18 dec)
        IERC20Minimal(M_XAUT).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_XAUT).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(swapRouter), type(uint256).max);

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower = ((tick - 5580) / 60) * 60;
        int24 upper = ((tick + 5580) / 60) * 60;
        // ~98k wstGBP + ~49 XAUT over ±5580 ticks — the canonical XAUT fixture's economic scale.
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 9e15, salt: 0}), ""
        );
    }

    /// @notice Mint side (wstGBP in) is `zeroForOne == false` in the flipped pool and pays the 30 bps
    ///         base; redeem side (XAUT in) is `zeroForOne == true` and pays 5 bps — the exact inverse
    ///         of the canonical pool's zeroForOne mapping, same fee schedule.
    function test_flipped_baseFeeMapping() public {
        // Probe sizes small enough that the first swap's own price impact stays inside the
        // 10 bps threshold band.
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD)); // 1 wstGBP in
        assertEq(mintFee, 3000, "mint side base");

        uint24 redeemFee = _swapAndReadFee(true, -int256(XAUT_UNIT / 1000)); // 0.001 XAUT in
        assertEq(redeemFee, 500, "redeem side base");
    }

    /// @notice d < 0 (fair above pool — gold rallied, the token–metal-basis geometry): mint side
    ///         closes and pays the surcharge — in flipped zeroForOne terms, the `false` direction.
    function test_flipped_surchargeDirectionMapping() public {
        xauUsd.set(2550e8, block.timestamp); // gold +2% => fair +2% => d ~ -19600 ppm
        uint24 mintFee = _swapAndReadFee(false, -int256(100 * WAD));
        // surcharge = min((|d| - 1000) * 0.5, 6000): |d| ~19600 -> 9300 > cap => 6000.
        assertEq(mintFee, 9000, "mint base + cap");
    }

    /// @notice d > 0 (gold dropped, fair fell — the ratchet-analog geometry): redeem side
    ///         (zeroForOne == true here) pays; mint side pays base only.
    function test_flipped_oppositeDeviationPaysRedeemSide() public {
        xauUsd.set(2450e8, block.timestamp); // gold -2% => fair -2% => d ~ +20400 ppm
        uint24 redeemFee = _swapAndReadFee(true, -int256(XAUT_UNIT / 100));
        assertEq(redeemFee, 6500, "redeem base + cap");

        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000, "opener pays base");
    }

    /// @notice The un-inverted pool-price branch: at init the pool price equals fair exactly (up to
    ///         isqrt flooring), so deviation is ~0 and both sides pay base. A wrong XAUT_UNIT
    ///         constant in this branch would read fair off by 1e12 and saturate every fee.
    function test_flipped_priceBranchReadsFairAtInit() public {
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000);
        uint24 redeemFee = _swapAndReadFee(true, -int256(XAUT_UNIT / 1000));
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
            xauUsdStalenessSec: 90_000,
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

contract MockXautToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @dev 6 like the real XAUT — the hook constructor asserts this.
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
contract MockWrapperToken is MockXautToken {
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
