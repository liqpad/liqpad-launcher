// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DiemEngine} from "../src/DiemEngine.sol";
import {IVeniceAdapter} from "../src/interfaces/IVeniceAdapter.sol";

contract EngineToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
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

contract MockVeniceAdapter is IVeniceAdapter {
    EngineToken public token;
    address public engine;
    uint256 public unlocked;
    uint256 public locked;
    uint256 public liquidDiem;
    uint256 public stakedDiem;
    uint256 public unwindAmount;
    UnwindStage public unwindStage;
    bool public attackHarvest;
    bool public attackUnwind;
    bool public reentryBlocked;

    constructor(EngineToken token_) {
        token = token_;
    }

    function bind(address engine_) external {
        require(engine == address(0));
        engine = engine_;
    }

    function VVV() external view returns (address) {
        return address(token);
    }

    function SVVV() external pure returns (address) {
        return address(0x5111);
    }

    function DIEM() external pure returns (address) {
        return address(0xD1E0);
    }

    function stakeVVV(uint256 amount) external returns (uint256) {
        if (attackHarvest) {
            (bool ok,) = engine.call(abi.encodeCall(DiemEngine.harvest, ()));
            reentryBlocked = !ok;
        }
        token.transferFrom(msg.sender, address(this), amount);
        unlocked += amount;
        return amount;
    }

    function unlockedSVVV() external view returns (uint256) {
        return unlocked;
    }

    function quoteDiem(uint256 amount) external pure returns (uint256) {
        return amount * 2;
    }

    function mintDiem(uint256 amount, uint256 minOut) external returns (uint256 out) {
        out = amount * 2;
        require(out >= minOut);
        unlocked -= amount;
        locked += amount;
        liquidDiem += out;
    }

    function stakeDiem(uint256 amount) external {
        liquidDiem -= amount;
        stakedDiem += amount;
    }

    function beginUnwind(uint256 amount) external {
        require(unwindStage == UnwindStage.Idle);
        unwindAmount = amount;
        stakedDiem -= amount;
        unwindStage = UnwindStage.DiemCooldown;
    }

    function finalizeUnwind() external returns (UnwindStage stage, uint256 burned, uint256 svvv, uint256 recovered) {
        if (attackUnwind) {
            (bool ok,) = engine.call(abi.encodeCall(DiemEngine.finalizeUnwind, ()));
            reentryBlocked = !ok;
        }
        if (unwindStage == UnwindStage.DiemCooldown) {
            burned = unwindAmount;
            svvv = burned / 2;
            locked -= svvv;
            unwindStage = UnwindStage.SVVVCooldown;
        } else {
            recovered = unwindAmount / 2;
            token.mint(engine, recovered);
            unwindStage = UnwindStage.Idle;
            unwindAmount = 0;
        }
        stage = unwindStage;
    }

    function setAttack(bool harvest_, bool unwind_) external {
        attackHarvest = harvest_;
        attackUnwind = unwind_;
        reentryBlocked = false;
    }
}

contract DiemEngineTest is Test {
    EngineToken token;
    MockVeniceAdapter adapter;
    DiemEngine engine;
    address owner = address(0xA11CE);
    address caller = address(0xB0B);

    function setUp() public {
        token = new EngineToken();
        adapter = new MockVeniceAdapter(token);
        engine = new DiemEngine(owner, adapter, 100e18, 2 days, true);
        adapter.bind(address(engine));
    }

    function test_permissionlessHarvestStakesReserveAndMintsDiem() public {
        token.mint(address(engine), 1_000e18);
        vm.prank(caller);
        engine.harvest();
        assertEq(engine.vvvReceived(), 1_000e18);
        assertEq(engine.vvvStaked(), 950e18);
        assertEq(token.balanceOf(address(engine)), 50e18);
        assertEq(engine.sVVVLocked(), 950e18);
        assertEq(engine.diemMinted(), 1_900e18);
        assertEq(engine.diemStaked(), 1_900e18);
        assertEq(engine.diemLiquid(), 0);
        vm.prank(caller);
        engine.compound();
        assertEq(engine.vvvStaked(), 950e18);
        assertEq(engine.diemMinted(), 1_900e18);
    }

    function test_harvestBelowThresholdIsIdempotent() public {
        vm.prank(owner);
        engine.setMinMintSVVV(2_000e18);
        token.mint(address(engine), 1_000e18);
        vm.prank(caller);
        engine.harvest();
        vm.prank(caller);
        engine.harvest();
        assertEq(engine.vvvStaked(), 950e18);
        assertEq(engine.diemMinted(), 0);
        assertEq(token.balanceOf(address(engine)), 50e18);
    }

    function test_harvestWithZeroVVVIsNoOp() public {
        vm.prank(caller);
        engine.harvest();
        assertEq(engine.vvvReceived(), 0);
        assertEq(engine.vvvStaked(), 0);
        assertEq(engine.sVVVLocked(), 0);
        assertEq(engine.diemMinted(), 0);
        assertEq(token.balanceOf(address(engine)), 0);
    }

    function test_wrongAdapterAndWrongCallerCannotStealVVV() public {
        token.mint(address(engine), 1_000e18);
        engine.harvest();
        assertEq(token.allowance(address(engine), address(adapter)), 0);
        MockVeniceAdapter wrong = new MockVeniceAdapter(token);
        assertEq(token.allowance(address(engine), address(wrong)), 0);
        vm.expectRevert();
        token.transferFrom(address(engine), address(this), 1);
    }

    function test_unwindBurnsDiemThenRecoversSVVVAsVVV() public {
        token.mint(address(engine), 1_000e18);
        engine.harvest();
        vm.prank(owner);
        engine.beginUnwind(1_000e18);
        vm.prank(owner);
        vm.expectRevert(DiemEngine.TimelockActive.selector);
        engine.finalizeUnwind();
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        engine.finalizeUnwind();
        vm.prank(owner);
        engine.finalizeUnwind();
        assertEq(engine.diemMinted(), 900e18);
        assertEq(engine.sVVVLocked(), 450e18);
        vm.prank(owner);
        engine.finalizeUnwind();
        assertEq(engine.pendingUnwindDiem(), 0);
        assertEq(token.balanceOf(address(engine)), 550e18);
    }

    function test_reentrancyBlockedOnHarvestAndUnwind() public {
        token.mint(address(engine), 1_000e18);
        adapter.setAttack(true, false);
        engine.harvest();
        assertTrue(adapter.reentryBlocked());
        vm.prank(owner);
        engine.beginUnwind(100e18);
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        engine.finalizeUnwind();
        adapter.setAttack(false, true);
        vm.prank(owner);
        engine.finalizeUnwind();
        assertTrue(adapter.reentryBlocked());
    }

    function test_pauseAndReserveCap() public {
        vm.prank(owner);
        engine.setHarvestPaused(true);
        vm.expectRevert(DiemEngine.HarvestPaused.selector);
        engine.harvest();
        vm.prank(owner);
        vm.expectRevert(DiemEngine.ReserveTooHigh.selector);
        engine.setReserveBps(2_001);
    }
}
