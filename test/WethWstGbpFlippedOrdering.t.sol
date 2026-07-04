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

import {WethWstGbpHook} from "../src/weth/WethWstGbpHook.sol";
import {FeeMath} from "../src/weth/lib/FeeMath.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";
import {IAggregatorV3} from "../src/weth/interfaces/IAggregatorV3.sol";

// Addresses chosen so the mock "WETH" sorts BELOW the mock wrapper — the flipped ordering the real
// WETH/wstGBP pair (wstGBP 0x57C3… < WETH 0xC02a…) never produces. Etched so ordering is deterministic.
address constant M_WETH = address(uint160(0xA0000));
address constant M_WSGBP = address(uint160(0xB0000));

/// @notice End-to-end fee checks in the FLIPPED ordering (`wstGbpIsCurrency0 == false`: WETH is
///         currency0). The real-pair suite only exercises `wstGbpIsCurrency0 == true`; this proves the
///         direction mapping and the pool-price inversion branch adapt: here mint side (wstGBP in) is
///         `zeroForOne == false` and the un-inverted price branch is the live one. Uses the real
///         (forked) PoolManager with mock tokens etched at addresses we order ourselves; NAV 1e18 and
///         round feed numbers isolate direction from price.
contract WethWstGbpFlippedOrderingTest is Test {
    uint256 constant WAD = 1e18;
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    bytes32 constant PM_SWAP_SIG = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    // ETH $2500, GBP $1.25, NAV 1.0 => fair = 2000 wstGBP per WETH.
    uint256 constant FAIR = 2000e18;

    WethWstGbpHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    FlippedMockFeed ethUsd;
    FlippedMockFeed gbpUsd;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(vm.envOr("ETH_RPC_URL", string("https://ethereum-rpc.publicnode.com")));

        vm.etch(M_WETH, address(new MockToken()).code);
        vm.etch(M_WSGBP, address(new MockWrapperToken()).code);
        assertTrue(M_WETH < M_WSGBP, "test premise: WETH sorts below the wrapper");

        ethUsd = new FlippedMockFeed();
        gbpUsd = new FlippedMockFeed();
        ethUsd.set(2500e8, block.timestamp);
        gbpUsd.set(1.25e8, block.timestamp);

        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        bytes memory args = abi.encode(
            PM,
            IAggregatorV3(address(ethUsd)),
            IAggregatorV3(address(gbpUsd)),
            Iwsgem(M_WSGBP),
            M_WETH,
            _params(),
            address(this)
        );
        (address hookAddr, bytes32 salt) = HookMiner.find(address(this), flags, type(WethWstGbpHook).creationCode, args);
        hook = new WethWstGbpHook{salt: salt}(
            PM,
            IAggregatorV3(address(ethUsd)),
            IAggregatorV3(address(gbpUsd)),
            Iwsgem(M_WSGBP),
            M_WETH,
            _params(),
            address(this)
        );
        assertEq(address(hook), hookAddr, "mined address");

        // The whole point: the constructor resolved the flipped ordering.
        assertFalse(hook.wstGbpIsCurrency0(), "wstGBP is currency1 here");
        assertEq(Currency.unwrap(hook.currency0()), M_WETH);
        assertEq(Currency.unwrap(hook.currency1()), M_WSGBP);

        key = PoolKey({
            currency0: Currency.wrap(M_WETH),
            currency1: Currency.wrap(M_WSGBP),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        // Flipped: raw pool price (currency1 per currency0) IS wstGBP-per-WETH = fair.
        uint160 sqrtP = uint160(_isqrt(((FAIR << 96) / WAD) << 96));
        PM.initialize(key, sqrtP);

        swapRouter = new PoolSwapTest(PM);
        lpRouter = new PoolModifyLiquidityTest(PM);
        MockToken(M_WETH).mint(address(this), 1e24);
        MockToken(M_WSGBP).mint(address(this), 1e27);
        IERC20Minimal(M_WETH).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(lpRouter), type(uint256).max);
        IERC20Minimal(M_WETH).approve(address(swapRouter), type(uint256).max);
        IERC20Minimal(M_WSGBP).approve(address(swapRouter), type(uint256).max);

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtP);
        int24 lower = ((tick - 5580) / 60) * 60;
        int24 upper = ((tick + 5580) / 60) * 60;
        lpRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e21, salt: 0}), ""
        );
    }

    /// @notice Mint side (wstGBP in) is `zeroForOne == false` in the flipped pool and pays the 30 bps
    ///         base; redeem side (WETH in) is `zeroForOne == true` and pays 5 bps — the exact inverse
    ///         of the canonical pool's zeroForOne mapping, same fee schedule.
    function test_flipped_baseFeeMapping() public {
        // Probe sizes small enough that the first swap's own price impact stays inside the
        // 10 bps threshold band (LP here is thinner than the canonical fixture's).
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD)); // 1 wstGBP in
        assertEq(mintFee, 3000, "mint side base");

        uint24 redeemFee = _swapAndReadFee(true, -int256(WAD / 1000)); // 0.001 WETH in
        assertEq(redeemFee, 500, "redeem side base");
    }

    /// @notice d < 0 (fair above pool): mint side closes and pays the surcharge — in flipped
    ///         zeroForOne terms, the `false` direction.
    function test_flipped_surchargeDirectionMapping() public {
        ethUsd.set(2550e8, block.timestamp); // fair +2% => d ~ -19600 ppm
        uint24 mintFee = _swapAndReadFee(false, -int256(100 * WAD));
        // surcharge = min((|d| - 1000) * 0.5, 6000) saturates? |d| ~19600 -> 9300 > cap => 6000.
        assertEq(mintFee, 9000, "mint base + cap");
    }

    /// @notice d > 0: redeem side (zeroForOne == true here) pays; mint side pays base only.
    function test_flipped_oppositeDeviationPaysRedeemSide() public {
        ethUsd.set(2450e8, block.timestamp); // fair -2% => d ~ +20400 ppm
        uint24 redeemFee = _swapAndReadFee(true, -int256(WAD / 100));
        assertEq(redeemFee, 6500, "redeem base + cap");

        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000, "opener pays base");
    }

    /// @notice The un-inverted pool-price branch: at init the pool price equals fair exactly (up to
    ///         isqrt flooring), so deviation is ~0 and both sides pay base.
    function test_flipped_priceBranchReadsFairAtInit() public {
        uint24 mintFee = _swapAndReadFee(false, -int256(WAD));
        assertEq(mintFee, 3000);
        uint24 redeemFee = _swapAndReadFee(true, -int256(WAD / 1000));
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
            ethUsdStalenessSec: 4500,
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

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

/// @dev The wrapper mock is a MockToken that also answers `navprice()` (all the hook reads off it).
contract MockWrapperToken is MockToken {
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
