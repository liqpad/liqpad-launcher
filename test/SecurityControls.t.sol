// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {LockedPositionVault} from "../src/LockedPositionVault.sol";
import {VeniceAdapter} from "../src/adapters/VeniceAdapter.sol";
import {DeploySepolia} from "../script/DeploySepolia.s.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract SecurityToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
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
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockPositionManager {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => uint128) public liquidityOf;
    uint256 public nextTokenId = 1;

    function mintLocked(address vault, uint256 tokenId) external {
        ownerOf[tokenId] = vault;
        bytes4 result = IERC721Receiver(vault).onERC721Received(msg.sender, address(0), tokenId, "");
        require(result == IERC721Receiver.onERC721Received.selector);
    }

    function modifyLiquidities(bytes calldata unlockData, uint256) external {
        (, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        (,,, uint256 liquidity,,, address recipient,) =
            abi.decode(params[0], (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
        uint256 tokenId = nextTokenId++;
        ownerOf[tokenId] = recipient;
        liquidityOf[tokenId] = uint128(liquidity);
        IERC721Receiver(recipient).onERC721Received(address(this), address(0), tokenId, "");
    }
}

contract MockPermit2 {
    mapping(address => mapping(address => uint160)) public allowance;

    function approve(address token, address spender, uint160 amount, uint48) external {
        allowance[token][spender] = amount;
    }
}

contract SecurityControlsTest is Test {
    address constant CREATOR = address(0xC0FFEE);
    address constant OWNER = address(0xA11CE);
    address constant ENGINE = address(0xD1E0);
    address constant HOOK = address(0x20CC);

    function test_adapterBindEngineIsOneShotAndOnlyConfigurator() external {
        SecurityToken vvv = new SecurityToken();
        SecurityToken svvv = new SecurityToken();
        SecurityToken diem = new SecurityToken();
        VeniceAdapter adapter = new VeniceAdapter(address(this), address(vvv), address(svvv), address(diem));
        vm.prank(address(0xBAD));
        vm.expectRevert(VeniceAdapter.OnlyConfigurator.selector);
        adapter.bindEngine(ENGINE);
        adapter.bindEngine(ENGINE);
        vm.expectRevert(VeniceAdapter.AlreadyConfigured.selector);
        adapter.bindEngine(address(0xBEEF));
        vm.prank(address(0xBEEF));
        vm.expectRevert(VeniceAdapter.OnlyEngine.selector);
        adapter.stakeVVV(1);
        assertEq(adapter.engine(), ENGINE);
    }

    function test_ownerCannotDrainCreatorClaim() external {
        SecurityToken vvv = new SecurityToken();
        FeeRouter router = new FeeRouter(address(vvv), address(this), ENGINE);
        router.bindHook(HOOK);
        address launch = address(0xB200);
        vm.prank(HOOK);
        router.registerLaunch(launch, CREATOR);
        vvv.mint(address(router), 1_000e18);
        vm.prank(HOOK);
        router.accrue(launch, 1_000e18);
        vm.prank(OWNER);
        assertEq(router.claim(launch), 0);
        vm.prank(ENGINE);
        assertEq(router.claim(launch), 0);
        assertEq(router.creatorAccrued(CREATOR, launch), 700e18);
        router.sweepPlatform();
        assertEq(vvv.balanceOf(ENGINE), 300e18);
        vm.prank(CREATOR);
        assertEq(router.claim(launch), 700e18);
    }

    function test_lockedPositionHasNoWithdrawOrApprovalPath() external {
        MockPositionManager manager = new MockPositionManager();
        LockedPositionVault vault = new LockedPositionVault(address(manager), address(0x2222), address(this));
        manager.mintLocked(address(vault), 77);
        assertEq(manager.ownerOf(77), address(vault));
        (bool transferOk,) = address(vault)
            .call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(vault), OWNER, 77));
        (bool approveOk,) = address(vault).call(abi.encodeWithSignature("approve(address,uint256)", OWNER, 77));
        assertFalse(transferOk);
        assertFalse(approveOk);
        vm.prank(OWNER);
        vm.expectRevert(LockedPositionVault.OnlyPositionManager.selector);
        vault.onERC721Received(OWNER, address(0), 78, "");
    }

    function test_lockMintsNonzeroPositionDirectlyToVault() external {
        MockPositionManager manager = new MockPositionManager();
        MockPermit2 permit = new MockPermit2();
        SecurityToken b20 = new SecurityToken();
        address vvv = address(new SecurityToken());
        LockedPositionVault vault = new LockedPositionVault(address(manager), address(permit), address(this));
        b20.mint(address(vault), 1_000_000_000e18);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(b20)),
            currency1: Currency.wrap(vvv),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(address(0x1234))
        });

        uint256 tokenId = vault.lock(key, address(b20), 1_000_000_000e18, 200, 887_200);
        assertEq(manager.ownerOf(tokenId), address(vault));
        assertGt(manager.liquidityOf(tokenId), 0);
        assertEq(b20.allowance(address(vault), address(permit)), 0);
        assertEq(permit.allowance(address(b20), address(manager)), 0);
    }

    function test_sepoliaDeploymentMocksFailClosedOnWrongChain() external {
        assertTrue(block.chainid != 84_532);
        DeploySepolia script = new DeploySepolia();
        vm.expectRevert(bytes("BASE_SEPOLIA_ONLY"));
        script.run();
    }
}
