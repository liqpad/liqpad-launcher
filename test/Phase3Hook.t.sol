// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {LiqpadLaunchHook} from "../src/LiqpadLaunchHook.sol";

contract MockFeeToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
    }
}

contract Phase3ActualPoolTest is Test {
    MockFeeToken internal vvv;
    MockFeeToken internal b20;
    PoolManager internal manager;
    FeeRouter internal router;
    LiqpadLaunchHook internal hook;
    PoolKey internal key;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;
    address internal constant CREATOR = address(0xCAFE);
    address internal constant DIEM = address(0xD1E0);

    function setUp() public {
        vvv = new MockFeeToken("Venice", "VVV");
        b20 = new MockFeeToken("Launch", "B20");
        manager = new PoolManager(address(this));
        router = new FeeRouter(address(vvv), address(this), DIEM);
        TestableLaunchHook implementation = new TestableLaunchHook(manager, address(vvv), address(this), router);
        address flagged = address(uint160((1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2)));
        vm.etch(flagged, address(implementation).code);
        hook = LiqpadLaunchHook(flagged);
        router.bindHook(flagged);
        (Currency c0, Currency c1) = address(vvv) < address(b20)
            ? (Currency.wrap(address(vvv)), Currency.wrap(address(b20)))
            : (Currency.wrap(address(b20)), Currency.wrap(address(vvv)));
        key = PoolKey(c0, c1, 0, 200, IHooks(flagged));
        hook.registerLaunchPool(key, address(b20), CREATOR);
        manager.initialize(key, uint160(1 << 96));
        liquidityRouter = new PoolModifyLiquidityTest(manager);
        swapRouter = new PoolSwapTest(manager);
        vvv.mint(address(this), 10_000_000e18);
        b20.mint(address(this), 10_000_000e18);
        vvv.approve(address(liquidityRouter), type(uint256).max);
        b20.approve(address(liquidityRouter), type(uint256).max);
        vvv.approve(address(swapRouter), type(uint256).max);
        b20.approve(address(swapRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887_200, tickUpper: 887_200, liquidityDelta: int256(1e24), salt: bytes32(0)
            }),
            ""
        );
    }

    function test_actualV4BuyAndSellApplyBurnAndSplit() public {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);
        bool vvvIs0 = Currency.unwrap(key.currency0) == address(vvv);
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(
                vvvIs0, -int256(10_000e18), vvvIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        assertEq(router.creatorAccrued(CREATOR, address(b20)), 70e18);
        assertEq(router.platformAccrued(), 30e18);
        uint256 supply = b20.totalSupply();
        swapRouter.swap(
            key,
            IPoolManager.SwapParams(
                !vvvIs0, -int256(5_000e18), !vvvIs0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            settings,
            ""
        );
        assertEq(b20.totalSupply(), supply - 50e18);
        assertGt(router.creatorAccrued(CREATOR, address(b20)), 70e18);
        assertGt(router.platformAccrued(), 30e18);
        assertEq(b20.balanceOf(address(router)), 0);
        assertEq(b20.balanceOf(address(hook)), 0);
    }

    function test_actualManagerRejectsUnregisteredPoolInitialization() public {
        MockFeeToken rogue = new MockFeeToken("Rogue", "ROGUE");
        (Currency c0, Currency c1) = address(vvv) < address(rogue)
            ? (Currency.wrap(address(vvv)), Currency.wrap(address(rogue)))
            : (Currency.wrap(address(rogue)), Currency.wrap(address(vvv)));
        PoolKey memory rogueKey = PoolKey(c0, c1, 0, 200, IHooks(address(hook)));
        vm.expectRevert();
        manager.initialize(rogueKey, uint160(1 << 96));
    }
}

contract MockTakeManager {
    function take(Currency currency, address to, uint256 amount) external {
        MockFeeToken(Currency.unwrap(currency)).transfer(to, amount);
    }
}

contract TestableLaunchHook is LiqpadLaunchHook {
    constructor(IPoolManager manager_, address vvv_, address factory_, FeeRouter router_)
        LiqpadLaunchHook(manager_, vvv_, factory_, router_)
    {}
    function validateHookAddress(BaseHook) internal pure override {}
}

contract Phase3HookTest is Test {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;
    MockFeeToken internal vvv;
    MockFeeToken internal b20;
    MockTakeManager internal manager;
    FeeRouter internal router;
    TestableLaunchHook internal hook;
    PoolKey internal key;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant DIEM = address(0xD1E0);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        vvv = new MockFeeToken("Venice", "VVV");
        b20 = new MockFeeToken("Launch", "B20");
        manager = new MockTakeManager();
        router = new FeeRouter(address(vvv), address(this), DIEM);
        hook = new TestableLaunchHook(IPoolManager(address(manager)), address(vvv), address(this), router);
        router.bindHook(address(hook));
        (Currency c0, Currency c1) = address(vvv) < address(b20)
            ? (Currency.wrap(address(vvv)), Currency.wrap(address(b20)))
            : (Currency.wrap(address(b20)), Currency.wrap(address(vvv)));
        key = PoolKey(c0, c1, 0, 200, IHooks(address(hook)));
        hook.registerLaunchPool(key, address(b20), CREATOR);
        vm.prank(address(manager));
        hook.beforeInitialize(address(this), key, uint160(1 << 96));
        vvv.mint(address(manager), 10_000_000e18);
        b20.mint(address(manager), 10_000_000e18);
    }

    function test_buy_skimsVVVAndSplitsSeventyThirty() public {
        IPoolManager.SwapParams memory p = _params(true, 100_000e18);
        vm.prank(address(manager));
        (, BeforeSwapDelta d,) = hook.beforeSwap(address(this), key, p, "");
        assertEq(d.getSpecifiedDelta(), int128(1_000e18));
        assertEq(router.creatorAccrued(CREATOR, address(b20)), 700e18);
        assertEq(router.platformAccrued(), 300e18);
        assertEq(vvv.balanceOf(address(router)), 1_000e18);
        assertEq(b20.balanceOf(address(router)), 0);
    }

    function test_sell_burnsB20AndSkimsVVVOutput() public {
        uint256 supplyBefore = b20.totalSupply();
        IPoolManager.SwapParams memory p = _params(false, 100_000e18);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        assertEq(b20.totalSupply(), supplyBefore - 1_000e18);
        assertEq(b20.balanceOf(address(hook)), 0);
        assertEq(b20.balanceOf(address(router)), 0);

        BalanceDelta delta = Currency.unwrap(key.currency0) == address(vvv)
            ? toBalanceDelta(int128(50_000e18), 0)
            : toBalanceDelta(0, int128(50_000e18));
        vm.prank(address(manager));
        (, int128 afterFee) = hook.afterSwap(address(this), key, p, delta, "");
        assertEq(afterFee, int128(500e18));
        assertEq(router.creatorAccrued(CREATOR, address(b20)), 350e18);
        assertEq(router.platformAccrued(), 150e18);
        assertEq(b20.balanceOf(address(router)), 0);
    }

    function test_creatorCannotClaimPlatformShare_andPlatformCannotClaimCreatorShare() public {
        IPoolManager.SwapParams memory p = _params(true, 100_000e18);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        vm.prank(DIEM);
        assertEq(router.claim(address(b20)), 0);
        assertEq(vvv.balanceOf(DIEM), 0);
        vm.prank(CREATOR);
        assertEq(router.claim(address(b20)), 700e18);
        assertEq(vvv.balanceOf(CREATOR), 700e18);
        assertEq(router.platformAccrued(), 300e18);
        router.sweepPlatform();
        assertEq(vvv.balanceOf(DIEM), 300e18);
    }

    function test_nonLiqpadPoolAndExactOutputRevert() public {
        PoolKey memory bad = key;
        bad.fee = 3_000;
        vm.expectRevert(LiqpadLaunchHook.InvalidLaunchPool.selector);
        hook.registerLaunchPool(bad, address(b20), CREATOR);
        IPoolManager.SwapParams memory p = _params(true, 100e18);
        p.amountSpecified = int256(100e18);
        vm.prank(address(manager));
        vm.expectRevert(LiqpadLaunchHook.ExactOutputDisabled.selector);
        hook.beforeSwap(address(this), key, p, "");
    }

    function testFuzz_invariant_burnedB20NeverSitsInRouter(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 100, 1_000_000e18);
        IPoolManager.SwapParams memory p = _params(false, amount);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        assertEq(b20.balanceOf(address(router)), 0);
        assertEq(b20.balanceOf(address(hook)), 0);
    }

    function testFuzz_invariant_vvvFeeConservedAndCannotBeCrossClaimed(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 100, 1_000_000e18);
        IPoolManager.SwapParams memory p = _params(true, amount);
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, p, "");
        uint256 fee = amount / 100;
        uint256 creatorShare = router.creatorAccrued(CREATOR, address(b20));
        uint256 platformShare = router.platformAccrued();
        assertEq(creatorShare + platformShare, fee);
        vm.prank(DIEM);
        assertEq(router.claim(address(b20)), 0);
        vm.prank(ATTACKER);
        assertEq(router.claim(address(b20)), 0);
        assertEq(router.creatorAccrued(CREATOR, address(b20)), creatorShare);
        assertEq(router.platformAccrued(), platformShare);
    }

    function _params(bool buy, uint256 amount) private view returns (IPoolManager.SwapParams memory p) {
        bool vvvIs0 = Currency.unwrap(key.currency0) == address(vvv);
        p.zeroForOne = buy ? vvvIs0 : !vvvIs0;
        p.amountSpecified = -int256(amount);
        p.sqrtPriceLimitX96 = p.zeroForOne
            ? uint160(4_295_128_740)
            : uint160(1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342);
    }
}
