// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {RpcUrl} from "./base/RpcUrl.sol";
import {WsgemBackstopHook} from "../src/v4/WsgemBackstopHook.sol";
import {WsgemSwapRouter} from "../src/v4/periphery/WsgemSwapRouter.sol";
import {WsgemQuoter} from "../src/v4/periphery/WsgemQuoter.sol";
import {Iwsgem} from "../src/core/interfaces/Iwsgem.sol";

// Mock addresses chosen so the wrapper (wsgem) sorts BELOW its underlying (gem) — the flipped ordering the
// real tGBP/wstGBP pair (gem < wsgem) never produces. The mocks are etched at these exact addresses so the
// ordering is deterministic; the mocks therefore hardcode the cross-references as constants.
address constant M_WSGEM = address(uint160(0xA0000));
address constant M_GEM = address(uint160(0xB0000));
address constant M_ACT = address(uint160(0xC0000));
address constant M_PIP = address(uint160(0xD0000));

/// @notice End-to-end swaps in the FLIPPED token ordering (wsgem = currency0, gem = currency1, so
///         `gemIsZero == false`). The real-pair suites only ever exercise `gemIsZero == true`; this proves
///         the hook adapts: a buy is `zeroForOne == false` here (pay currency1 = gem) and a sell is
///         `zeroForOne == true` (pay currency0 = wsgem), the inverse of the canonical pool. Uses the real
///         (forked) PoolManager — v4-core's `PoolManager` is solc-pinned to 0.8.26 and can't be deployed
///         under this 0.8.28 project — with mock tokens etched at addresses we order ourselves. mintcost ==
///         burncost == 1 (NAV 1e18, zero spread) so amounts are exact 1:1, isolating direction from price.
contract WsgemFlippedOrderingHookTest is Test {
    uint256 constant WAD = 1e18;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    WsgemBackstopHook hook;
    WsgemSwapRouter router;
    WsgemQuoter quoter;
    PoolKey key;

    function setUp() public {
        vm.createSelectFork(RpcUrl.resolve(vm));

        // Etch the mocks at the chosen (ordered) addresses: wsgem below gem ⇒ flipped ordering.
        vm.etch(M_PIP, address(new MockPip()).code);
        vm.etch(M_ACT, address(new MockAct()).code);
        vm.etch(M_GEM, address(new MockGem()).code);
        vm.etch(M_WSGEM, address(new MockWrapper()).code);
        assertTrue(M_WSGEM < M_GEM, "test premise: wsgem sorts below gem");

        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        bytes memory args = abi.encode(PM, Iwsgem(M_WSGEM));
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(WsgemBackstopHook).creationCode, args);
        hook = new WsgemBackstopHook{salt: salt}(PM, Iwsgem(M_WSGEM));
        assertEq(address(hook), hookAddr, "mined address");

        // The whole point: the hook resolved the flipped ordering in its constructor.
        assertFalse(hook.gemIsZero(), "gemIsZero == false (gem is currency1)");
        assertEq(Currency.unwrap(hook.currency0()), M_WSGEM, "currency0 == wsgem");
        assertEq(Currency.unwrap(hook.currency1()), M_GEM, "currency1 == gem");

        router = new WsgemSwapRouter(PM);
        quoter = new WsgemQuoter(Iwsgem(M_WSGEM));
        assertFalse(quoter.gemIsZero(), "quoter mirrors gemIsZero");

        key = PoolKey({
            currency0: Currency.wrap(M_WSGEM),
            currency1: Currency.wrap(M_GEM),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(hook))
        });
        PM.initialize(key, SQRT_PRICE_1_1);

        // Reserves so redeems (sells) can pay out gem; and gem for this contract to buy with.
        MockGem(M_GEM).mint(M_WSGEM, 1_000_000 * WAD);
        MockGem(M_GEM).mint(address(this), 1_000_000 * WAD);
        IERC20Minimal(M_GEM).approve(address(router), type(uint256).max);
        IERC20Minimal(M_WSGEM).approve(address(router), type(uint256).max);
    }

    /// @notice A BUY of wsgem in the flipped pool pays gem = currency1, so it is `zeroForOne == false`. The
    ///         hook must route it to `mint` (not `redeem`) and deliver wsgem.
    function test_flippedOrdering_buyExactInputMints() public {
        uint256 gemIn = 1_000 * WAD;
        uint256 wsgemBefore = IERC20Minimal(M_WSGEM).balanceOf(address(this));

        // Buy = pay currency1 (gem) = oneForZero = zeroForOne false.
        uint256 outQuoted = quoter.quoteExactInput(false, gemIn);
        uint256 out = router.swapExactInput(key, false, gemIn, 0, address(this), block.timestamp);

        assertEq(out, gemIn, "1:1 at NAV 1, no spread");
        assertEq(out, outQuoted, "quoter matches execution (flipped buy)");
        assertEq(IERC20Minimal(M_WSGEM).balanceOf(address(this)) - wsgemBefore, out, "received wsgem");
        _assertHookClean();
    }

    /// @notice A SELL of wsgem in the flipped pool pays wsgem = currency0, so it is `zeroForOne == true`. The
    ///         hook must route it to `redeem` (not `mint`) and deliver gem.
    function test_flippedOrdering_sellExactInputRedeems() public {
        // Acquire wsgem to sell, via a (flipped) buy.
        router.swapExactInput(key, false, 5_000 * WAD, 0, address(this), block.timestamp);

        uint256 wsgemIn = 1_000 * WAD;
        uint256 gemBefore = IERC20Minimal(M_GEM).balanceOf(address(this));

        // Sell = pay currency0 (wsgem) = zeroForOne true.
        uint256 outQuoted = quoter.quoteExactInput(true, wsgemIn);
        uint256 out = router.swapExactInput(key, true, wsgemIn, 0, address(this), block.timestamp);

        assertEq(out, wsgemIn, "1:1 at NAV 1, no spread");
        assertEq(out, outQuoted, "quoter matches execution (flipped sell)");
        assertEq(IERC20Minimal(M_GEM).balanceOf(address(this)) - gemBefore, out, "received gem");
        _assertHookClean();
    }

    /// @notice Exact-output works in the flipped ordering too: buy an exact wsgem amount paying gem.
    function test_flippedOrdering_buyExactOutput() public {
        uint256 wsgemOut = 1_000 * WAD;
        uint256 inQuoted = quoter.quoteExactOutput(false, wsgemOut);
        uint256 wsgemBefore = IERC20Minimal(M_WSGEM).balanceOf(address(this));

        // The router pre-settles maxAmountIn (refunding surplus), so pass an affordable bound.
        uint256 spent = router.swapExactOutput(key, false, wsgemOut, inQuoted + 1 * WAD, address(this), block.timestamp);

        assertEq(spent, inQuoted, "quoter matches execution (flipped exact-out buy)");
        assertEq(IERC20Minimal(M_WSGEM).balanceOf(address(this)) - wsgemBefore, wsgemOut, "exact wsgem out");
        _assertHookClean();
    }

    /// @notice Exact-output SELL in the flipped pool: redeem for an exact gem amount paying wsgem = currency0
    ///         (`zeroForOne == true`). Completes the flipped matrix — buy-in, sell-in and buy-out were
    ///         covered, but the exact-output redeem path under `gemIsZero == false` was not.
    function test_flippedOrdering_sellExactOutput() public {
        // Acquire wsgem to sell, via a (flipped) buy.
        router.swapExactInput(key, false, 5_000 * WAD, 0, address(this), block.timestamp);

        uint256 gemOut = 1_000 * WAD;
        uint256 inQuoted = quoter.quoteExactOutput(true, gemOut); // sell quote (zeroForOne true)
        uint256 gemBefore = IERC20Minimal(M_GEM).balanceOf(address(this));
        uint256 wsgemBefore = IERC20Minimal(M_WSGEM).balanceOf(address(this));

        uint256 spent = router.swapExactOutput(key, true, gemOut, inQuoted + 1 * WAD, address(this), block.timestamp);

        assertEq(spent, inQuoted, "quoter matches execution (flipped exact-out sell)");
        assertEq(spent, gemOut, "1:1 at NAV 1, no spread");
        assertEq(IERC20Minimal(M_GEM).balanceOf(address(this)) - gemBefore, gemOut, "exact gem out");
        assertEq(wsgemBefore - IERC20Minimal(M_WSGEM).balanceOf(address(this)), spent, "wsgem spent");
        _assertHookClean();
    }

    function _assertHookClean() internal view {
        assertEq(IERC20Minimal(M_GEM).balanceOf(address(hook)), 0, "hook holds no gem");
        assertEq(IERC20Minimal(M_WSGEM).balanceOf(address(hook)), 0, "hook holds no wsgem");
    }

    // PoolSwapTest-style native refund safety isn't needed (no native), but the router may refund — accept ETH.
    receive() external payable {}
}

// --- Mocks (etched at the constant addresses above; cross-references are hardcoded constants because etch
//     copies only runtime code, not constructor-set state) ---

contract MockPip {
    function read() external pure returns (uint256) {
        return 1e18;
    }
}

contract MockAct {
    function mintcost(uint256 p) external pure returns (uint256) {
        return p;
    }

    function burncost(uint256 p) external pure returns (uint256) {
        return p;
    }

    function cooldown() external pure returns (uint256) {
        return 0;
    }
}

contract MockGem {
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

/// @dev wsgem token (ERC20) + Iwsgem wrapper. mintcost == burncost == NAV == 1e18.
contract MockWrapper {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function gem() external pure returns (address) {
        return M_GEM;
    }

    function act() external pure returns (address) {
        return M_ACT;
    }

    function pip() external pure returns (address) {
        return M_PIP;
    }

    function mintable() external pure returns (bool) {
        return true;
    }

    function burnable() external pure returns (bool) {
        return true;
    }

    function capacity() external pure returns (uint256) {
        return type(uint256).max;
    }

    function cooldown() external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function canPass(address) external pure returns (bool) {
        return true;
    }

    // Hardcoded to match MockAct(mintcost==burncost==p) over MockPip(read==1e18), which is what the hook
    // prices off via WsgemWrap.price; keeping these as literals avoids an external call (and a needless
    // view→pure lint) while staying consistent with the hook's execution price.
    function navprice() external pure returns (uint256) {
        return 1e18;
    }

    function mintcost() public pure returns (uint256) {
        return 1e18;
    }

    function burncost() public pure returns (uint256) {
        return 1e18;
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

    function mint(uint256 amt) external returns (uint256 out) {
        MockGem(M_GEM).transferFrom(msg.sender, address(this), amt);
        out = amt * 1e18 / mintcost();
        balanceOf[msg.sender] += out;
    }

    function redeem(uint256 amt) external returns (uint256) {
        balanceOf[msg.sender] -= amt;
        uint256 gemOut = amt * burncost() / 1e18;
        MockGem(M_GEM).transfer(msg.sender, gemOut);
        return 1;
    }
}
