// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiqpadFactory, ILiqpadLaunchHook, IFeeRouterBinding, ILiqpadLiquidityLocker} from "../src/LiqpadFactory.sol";
import {LiqpadLaunchHook} from "../src/LiqpadLaunchHook.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {HookDeployer} from "../src/HookDeployer.sol";
import {LockedPositionVault} from "../src/LockedPositionVault.sol";
import {MockB20Factory} from "./mocks/MockB20Factory.sol";
import {MockB20} from "./mocks/MockB20.sol";
import {TestableLiqpadFactory} from "./mocks/TestableLiqpadFactory.sol";
import {MockQuoteSigner} from "./mocks/MockQuoteSigner.sol";
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
    address constant BASE_VVV = 0xacfE6019Ed1A7Dc6f7B508C02d1b04ec88cC21bf;

    struct FrameFixture {
        PoolManager manager;
        TestableLiqpadFactory factory;
        LockedPositionVault vault;
        RecordingPositionManager positionManager;
        LiqpadLaunchHook hook;
        address token;
        address vvv;
    }

    function test_create2HookAndOneShotWiring() external {
        PoolManager manager = new PoolManager(address(this));
        LiqpadFactory factory = new LiqpadFactory(address(this), address(new MockQuoteSigner()));
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
            manager, ILiqpadLaunchHook(address(hook)), vvv, IFeeRouterBinding(address(router)), locker
        );
        assertEq(router.hook(), address(hook));
        assertEq(address(factory.launchHook()), address(hook));
        assertEq(factory.configAdmin(), address(0));
    }

    function test_configuredLaunchLeavesOnlyHookBurnRole() external {
        PoolManager manager = new PoolManager(address(this));
        TestableLiqpadFactory factory =
            new TestableLiqpadFactory(new MockB20Factory(), address(this), address(new MockQuoteSigner()));
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
            manager, ILiqpadLaunchHook(address(hook)), vvv, IFeeRouterBinding(address(router)), locker
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
        MockB20 token = MockB20(factory.createLaunch(p, _quote(p), "valid"));
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

    function test_regressionProductionOrderingDoesNotRequireVVV() external {
        FrameFixture memory f = _launchFrameAt(BASE_VVV);
        assertLt(uint160(BASE_VVV), uint160(f.token));
        (int24 poolTick, int24 tickLower, int24 tickUpper) = f.factory.ticksFor(f.token, 144_800);
        assertEq(poolTick, 144_800);
        assertEq(tickLower, -887_200);
        assertEq(tickUpper, 144_800);
        assertEq(f.positionManager.amount0Max(), 0);
        assertEq(f.positionManager.amount1Max(), f.factory.TOKEN_SUPPLY());
        assertEq(WiringToken(BASE_VVV).balanceOf(address(0xC0FFEE)), 10e18);
        assertEq(f.positionManager.ownerOf(1), address(f.vault));
    }

    function test_configureRejectsUnalignedQuotedFrame() external {
        TestableLiqpadFactory factory =
            new TestableLiqpadFactory(new MockB20Factory(), address(this), address(new MockQuoteSigner()));
        LiqpadFactory.LaunchParams memory p = _frameParams(keccak256("unaligned"));
        LiqpadFactory.LaunchQuote memory quote = _quote(p);
        quote.quotedFrame = 144_801;
        vm.expectRevert(LiqpadFactory.InvalidQuotedFrame.selector);
        factory.createLaunch(p, quote, "valid");
    }

    function _assertCreateLaunchFrame(bool vvvIsToken0) private {
        FrameFixture memory f = _launchFrame(vvvIsToken0);
        (int24 poolTick, int24 tickLower, int24 tickUpper) = f.factory.ticksFor(f.token, 144_800);
        if (vvvIsToken0) {
            assertEq(poolTick, 144_800);
            assertEq(tickLower, TickMath.minUsableTick(200));
            assertEq(tickUpper, poolTick);
        } else {
            assertEq(poolTick, -144_800);
            assertEq(tickLower, poolTick);
            assertEq(tickUpper, TickMath.maxUsableTick(200));
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
        assertEq(MockB20(f.token).balanceOf(address(f.vault)), f.factory.TOKEN_SUPPLY());
        assertEq(f.positionManager.ownerOf(1), address(f.vault));
        assertGt(f.positionManager.liquidity(), 0);
        assertEq(f.positionManager.tickLower(), tickLower);
        assertEq(f.positionManager.tickUpper(), tickUpper);
        if (vvvIsToken0) {
            assertEq(f.positionManager.amount0Max(), 0);
            assertEq(f.positionManager.amount1Max(), f.factory.TOKEN_SUPPLY());
        } else {
            assertEq(f.positionManager.amount0Max(), f.factory.TOKEN_SUPPLY());
            assertEq(f.positionManager.amount1Max(), 0);
        }
        assertEq(WiringToken(f.vvv).balanceOf(address(0xC0FFEE)), 10e18);

        LiqpadFactory.Profile memory profile = f.factory.getProfile(f.token);
        assertEq(profile.creator, address(0xC0FFEE));
        assertEq(profile.description, "quoted frame test");
        assertEq(profile.contractURI, "ipfs://frame");
        assertTrue(f.factory.isLiqpadLaunch(f.token));
    }

    function _launchFrame(bool vvvIsToken0) private returns (FrameFixture memory f) {
        return _launchFrameAt(vvvIsToken0 ? address(0x10000) : address(type(uint160).max));
    }

    function _launchFrameAt(address vvv) private returns (FrameFixture memory f) {
        f.manager = new PoolManager(address(this));
        f.factory =
            new TestableLiqpadFactory(new MockB20Factory(), address(this), address(new MockQuoteSigner()));
        bytes32 launchSalt = keccak256(abi.encode("frame", vvv));
        if (vvv == BASE_VVV) {
            for (uint256 i; f.factory.predictAddress(launchSalt) < vvv; ++i) {
                launchSalt = keccak256(abi.encode("production-ordering", i));
            }
        }
        LiqpadFactory.LaunchParams memory p = LiqpadFactory.LaunchParams({
            name: "Frame Launch",
            symbol: "FRAME",
            salt: launchSalt,
            contractURI: "ipfs://frame",
            description: "quoted frame test",
            logoURI: "",
            website: "",
            socials: LiqpadFactory.Socials("", "", "", ""),
            creator: address(0xC0FFEE)
        });
        address predicted = f.factory.predictAddress(p.salt);
        f.vvv = vvv;
        WiringToken quoteImplementation = new WiringToken();
        vm.etch(f.vvv, address(quoteImplementation).code);
        WiringToken(f.vvv).mint(address(0xC0FFEE), 10e18);
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
        f.positionManager = new RecordingPositionManager();
        RecordingPermit2 permit2 = new RecordingPermit2();
        f.vault = new LockedPositionVault(address(f.positionManager), address(permit2), address(f.factory));
        f.factory
            .configurePhase3(
                f.manager,
                ILiqpadLaunchHook(address(f.hook)),
                f.vvv,
                IFeeRouterBinding(address(router)),
                ILiqpadLiquidityLocker(address(f.vault))
            );
        address predictedAgain = f.factory.predictAddress(p.salt);
        assertEq(predictedAgain, predicted);
        vm.recordLogs();
        f.token = f.factory.createLaunch(p, _quote(p), "valid");
        assertEq(f.token, predicted);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _assertLaunchEvent(f.factory, f.token, address(0xC0FFEE), logs);
    }

    function _assertLaunchEvent(TestableLiqpadFactory factory, address token, address creator, Vm.Log[] memory logs)
        private
        view
    {
        bytes32 launchSignature = keccak256("Launch(address,address,bytes32,bytes32)");
        bool launchFound;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(factory) && logs[i].topics[0] == launchSignature) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), token);
                assertEq(address(uint160(uint256(logs[i].topics[2]))), creator);
                assertEq(logs[i].topics[3], factory.getProfile(token).poolId);
                assertEq(abi.decode(logs[i].data, (bytes32)), factory.profileHash(token));
                launchFound = true;
            }
        }
        assertTrue(launchFound);
    }

    function _frameParams(bytes32 salt) private pure returns (LiqpadFactory.LaunchParams memory) {
        return LiqpadFactory.LaunchParams({
            name: "Frame Launch",
            symbol: "FRAME",
            salt: salt,
            contractURI: "ipfs://frame",
            description: "quoted frame test",
            logoURI: "",
            website: "",
            socials: LiqpadFactory.Socials("", "", "", ""),
            creator: address(0xC0FFEE)
        });
    }

    function _quote(LiqpadFactory.LaunchParams memory p)
        private
        view
        returns (LiqpadFactory.LaunchQuote memory)
    {
        return LiqpadFactory.LaunchQuote({
            quotedFrame: 144_800,
            validUntil: uint64(block.timestamp + 10 minutes),
            creator: p.creator,
            launchSalt: p.salt
        });
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

contract WiringToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract RecordingPermit2 {
    mapping(address => mapping(address => uint160)) public allowance;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowance[token][spender] = amount;
    }
}

contract RecordingPositionManager {
    mapping(uint256 => address) public ownerOf;
    uint256 public nextTokenId = 1;
    bytes public mintParams;

    function modifyLiquidities(bytes calldata unlockData, uint256) external {
        (, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        mintParams = params[0];
        address recipient = address(uint160(_word(10)));
        uint256 tokenId = nextTokenId++;
        ownerOf[tokenId] = recipient;
        IERC721Receiver(recipient).onERC721Received(address(this), address(0), tokenId, "");
    }

    function tickLower() external view returns (int24) {
        return int24(uint24(_word(5)));
    }

    function tickUpper() external view returns (int24) {
        return int24(uint24(_word(6)));
    }

    function liquidity() external view returns (uint128) {
        return uint128(_word(7));
    }

    function amount0Max() external view returns (uint128) {
        return uint128(_word(8));
    }

    function amount1Max() external view returns (uint128) {
        return uint128(_word(9));
    }

    function _word(uint256 index) private view returns (uint256 value) {
        bytes memory data = mintParams;
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), mul(index, 0x20)))
        }
    }
}

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
