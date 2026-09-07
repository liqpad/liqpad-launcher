// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiqpadFactory, ILiqpadLaunchHook, IFeeRouterBinding, ILiqpadLiquidityLocker} from "../src/LiqpadFactory.sol";
import {LiqpadLaunchHook} from "../src/LiqpadLaunchHook.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {MockB20Factory} from "./mocks/MockB20Factory.sol";
import {MockB20} from "./mocks/MockB20.sol";
import {TestableLiqpadFactory} from "./mocks/TestableLiqpadFactory.sol";
import {B20Constants} from "base-std/lib/B20Constants.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

contract DeployWiringTest is Test {
    using PoolIdLibrary for PoolKey;
    uint160 constant FLAGS = (1 << 13) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 constant MASK = (1 << 14) - 1;

    struct FrameFixture {
        PoolManager manager;
        TestableLiqpadFactory factory;
        MockLiquidityLocker locker;
        LiqpadLaunchHook hook;
        address token;
        address vvv;
    }

    function test_create2HookAndOneShotWiring() external {
        PoolManager manager = new PoolManager(address(this));
        LiqpadFactory factory = new LiqpadFactory();
        address vvv = address(new WiringToken());
        FeeRouter router = new FeeRouter(vvv, address(factory), address(0xD1E0));
        HookDeployer deployer = new HookDeployer();
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiqpadLaunchHook).creationCode,
                abi.encode(IPoolManager(address(manager)), vvv, address(factory), router)
            )
        );
        (bytes32 salt, address predicted) = _mine(address(deployer), initHash);
        LiqpadLaunchHook hook = deployer.deploy(salt, manager, vvv, address(factory), router);
        assertEq(address(hook), predicted);
        MockLiquidityLocker locker = new MockLiquidityLocker();
        factory.configurePhase3(
            manager, ILiqpadLaunchHook(address(hook)), vvv, IFeeRouterBinding(address(router)), locker, 115_200
        );
        assertEq(router.hook(), address(hook));
        assertEq(address(factory.launchHook()), address(hook));
        assertEq(factory.configAdmin(), address(0));
    }

    function test_configuredLaunchLeavesOnlyHookBurnRole() external {
        PoolManager manager = new PoolManager(address(this));
        TestableLiqpadFactory factory = new TestableLiqpadFactory(new MockB20Factory());
        address vvv = address(new WiringToken());
        FeeRouter router = new FeeRouter(vvv, address(factory), address(0xD1E0));
        HookDeployer deployer = new HookDeployer();
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiqpadLaunchHook).creationCode,
                abi.encode(IPoolManager(address(manager)), vvv, address(factory), router)
            )
        );
        (bytes32 hookSalt,) = _mine(address(deployer), initHash);
        LiqpadLaunchHook hook = deployer.deploy(hookSalt, manager, vvv, address(factory), router);
        MockLiquidityLocker locker = new MockLiquidityLocker();
        factory.configurePhase3(
            manager, ILiqpadLaunchHook(address(hook)), vvv, IFeeRouterBinding(address(router)), locker, 115_200
        );

        LiqpadFactory.LaunchParams memory p = LiqpadFactory.LaunchParams({
            name: "Secured Launch",
            symbol: "SEC",
            salt: keccak256("phase-6-role-test"),
            contractURI: "ipfs://security",
            description: "role invariant",
            logoURI: "",
            website: "",
            socials: LiqpadFactory.Socials("", "", "", ""),
            creator: address(0xC0FFEE)
        });
        MockB20 token = MockB20(factory.createLaunch(p));
        bytes32[3] memory forbidden = [bytes32(0), B20Constants.MINT_ROLE, B20Constants.PAUSE_ROLE];
        for (uint256 i; i < forbidden.length; ++i) {
            assertFalse(token.hasRole(forbidden[i], p.creator));
            assertFalse(token.hasRole(forbidden[i], address(factory)));
            assertFalse(token.hasRole(forbidden[i], address(hook)));
        }
        assertTrue(token.hasRole(B20Constants.BURN_ROLE, address(hook)));
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, p.creator));
        assertFalse(token.hasRole(B20Constants.BURN_ROLE, address(factory)));
    }

    function test_createLaunchUsesPositiveFrameWhenVVVIsToken0() external {
        _assertCreateLaunchFrame(true);
    }

    function test_createLaunchUsesNegativeFrameWhenVVVIsToken1() external {
        _assertCreateLaunchFrame(false);
    }

    function test_configureRejectsUnalignedQuotedFrame() external {
        LiqpadFactory factory = new LiqpadFactory();
        vm.expectRevert(LiqpadFactory.InvalidPhase3Config.selector);
        factory.configurePhase3(
            IPoolManager(address(1)),
            ILiqpadLaunchHook(address(2)),
            address(3),
            IFeeRouterBinding(address(4)),
            ILiqpadLiquidityLocker(address(5)),
            115_201
        );
    }

    function _assertCreateLaunchFrame(bool vvvIsToken0) private {
        FrameFixture memory f = _launchFrame(vvvIsToken0);
        (int24 poolTick, int24 tickLower, int24 tickUpper) = f.factory.ticksFor(f.token);
        if (vvvIsToken0) {
            assertEq(poolTick, 115_200);
            assertEq(tickLower, poolTick);
            assertEq(tickUpper, TickMath.maxUsableTick(200));
        } else {
            assertEq(poolTick, -115_200);
            assertEq(tickLower, TickMath.minUsableTick(200));
            assertEq(tickUpper, poolTick);
        }

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(f.token < f.vvv ? f.token : f.vvv),
            currency1: Currency.wrap(f.token < f.vvv ? f.vvv : f.token),
            fee: 0,
            tickSpacing: 200,
            hooks: f.hook
        });
        (uint160 sqrtPriceX96, int24 initializedTick,,) = StateLibrary.getSlot0(f.manager, key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(poolTick));
        assertEq(initializedTick, poolTick);
        assertEq(f.locker.token(), f.token);
        assertEq(f.locker.amount(), f.factory.TOKEN_SUPPLY());
        assertEq(f.locker.tickLower(), tickLower);
        assertEq(f.locker.tickUpper(), tickUpper);
        assertEq(MockB20(f.token).balanceOf(address(f.locker)), f.factory.TOKEN_SUPPLY());
    }

    function _launchFrame(bool vvvIsToken0) private returns (FrameFixture memory f) {
        f.manager = new PoolManager(address(this));
        f.factory = new TestableLiqpadFactory(new MockB20Factory());
        LiqpadFactory.LaunchParams memory p = LiqpadFactory.LaunchParams({
            name: "Frame Launch",
            symbol: "FRAME",
            salt: keccak256(abi.encode("frame", vvvIsToken0)),
            contractURI: "ipfs://frame",
            description: "quoted frame test",
            logoURI: "",
            website: "",
            socials: LiqpadFactory.Socials("", "", "", ""),
            creator: address(0xC0FFEE)
        });
        address predicted = f.factory.predictAddress(p.salt);
        f.vvv = vvvIsToken0 ? address(1) : address(type(uint160).max);
        assertEq(f.vvv < predicted, vvvIsToken0);
        FeeRouter router = new FeeRouter(f.vvv, address(f.factory), address(0xD1E0));
        HookDeployer deployer = new HookDeployer();
        bytes32 initHash = keccak256(
            abi.encodePacked(
                type(LiqpadLaunchHook).creationCode,
                abi.encode(IPoolManager(address(f.manager)), f.vvv, address(f.factory), router)
            )
        );
        (bytes32 hookSalt,) = _mine(address(deployer), initHash);
        f.hook = deployer.deploy(hookSalt, f.manager, f.vvv, address(f.factory), router);
        f.locker = new MockLiquidityLocker();
        f.factory
            .configurePhase3(
                f.manager,
                ILiqpadLaunchHook(address(f.hook)),
                f.vvv,
                IFeeRouterBinding(address(router)),
                f.locker,
                115_200
            );
        f.token = f.factory.createLaunch(p);
    }

    function _mine(address deployer, bytes32 initHash) private pure returns (bytes32 salt, address predicted) {
        for (uint256 i; i < 100_000; ++i) {
            salt = bytes32(i);
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initHash)))));
            if (uint160(predicted) & MASK == FLAGS) return (salt, predicted);
        }
        revert("salt");
    }
}

contract WiringToken {}

contract MockLiquidityLocker is ILiqpadLiquidityLocker {
    address public token;
    uint256 public amount;
    int24 public tickLower;
    int24 public tickUpper;

    function lock(PoolKey calldata, address token_, uint256 amount_, int24 tickLower_, int24 tickUpper_)
        external
        returns (uint256 tokenId)
    {
        token = token_;
        amount = amount_;
        tickLower = tickLower_;
        tickUpper = tickUpper_;
        return 1;
    }
}
