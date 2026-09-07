// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVeniceAdapter} from "../interfaces/IVeniceAdapter.sol";
import {IVeniceStaking} from "../interfaces/IVeniceStaking.sol";
import {IDiemMinter} from "../interfaces/IDiemMinter.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @title Typed Venice custody boundary for Liqpad protocol capital
/// @notice Stakes VVV, locks sVVV to mint DIEM, stakes DIEM, and advances verified unwind calls.
/// @dev Binds once to one engine and exposes no arbitrary call, EOA fee transfer, or collateral-withdraw bypass.
contract VeniceAdapter is IVeniceAdapter {
    address public immutable VVV;
    address public immutable SVVV;
    address public immutable DIEM;

    address public immutable configurator;
    address public engine;
    UnwindStage public unwindStage;
    uint256 public unwindDiem;
    uint256 public unwindSVVV;

    error OnlyEngine();
    error OnlyConfigurator();
    error AlreadyConfigured();
    error InvalidAmount();
    error WrongStage();
    error TransferFailed();

    constructor(address configurator_, address vvv_, address svvv_, address diem_) {
        if (configurator_ == address(0) || vvv_ == address(0) || svvv_ == address(0) || diem_ == address(0)) {
            revert InvalidAmount();
        }
        configurator = configurator_;
        VVV = vvv_;
        SVVV = svvv_;
        DIEM = diem_;
    }

    modifier onlyEngine() {
        if (msg.sender != engine) revert OnlyEngine();
        _;
    }

    function bindEngine(address engine_) external {
        if (msg.sender != configurator) revert OnlyConfigurator();
        if (engine != address(0) || engine_ == address(0)) revert AlreadyConfigured();
        engine = engine_;
    }

    function stakeVVV(uint256 amount) external onlyEngine returns (uint256 received) {
        uint256 beforeBalance = IVeniceStaking(SVVV).balanceOf(address(this));
        _transferFrom(VVV, msg.sender, address(this), amount);
        _approve(VVV, SVVV, amount);
        IVeniceStaking(SVVV).stake(address(this), amount);
        _approve(VVV, SVVV, 0);
        received = IVeniceStaking(SVVV).balanceOf(address(this)) - beforeBalance;
    }

    function unlockedSVVV() external view returns (uint256) {
        return IVeniceStaking(SVVV).balanceOfUnlocked(address(this));
    }

    function quoteDiem(uint256 amount) external view returns (uint256) {
        return IVeniceStaking(SVVV).getDiemAmountOut(amount);
    }

    function mintDiem(uint256 amount, uint256 minOut) external onlyEngine returns (uint256 out) {
        uint256 beforeBalance = IDiemMinter(DIEM).balanceOf(address(this));
        IVeniceStaking(SVVV).mintDiem(amount, minOut);
        out = IDiemMinter(DIEM).balanceOf(address(this)) - beforeBalance;
    }

    function stakeDiem(uint256 amount) external onlyEngine {
        IDiemMinter(DIEM).stake(amount);
    }

    function beginUnwind(uint256 amount) external onlyEngine {
        if (unwindStage != UnwindStage.Idle) revert WrongStage();
        if (amount == 0) revert InvalidAmount();
        (uint256 staked,,) = IDiemMinter(DIEM).stakedInfos(address(this));
        unwindDiem = amount;
        if (staked >= amount) {
            IDiemMinter(DIEM).initiateUnstake(amount);
            unwindStage = UnwindStage.DiemCooldown;
        } else {
            _burnAndStartSVVV(amount);
        }
    }

    function finalizeUnwind()
        external
        onlyEngine
        returns (UnwindStage stage, uint256 burned, uint256 unlocked, uint256 recovered)
    {
        if (unwindStage == UnwindStage.DiemCooldown) {
            IDiemMinter(DIEM).unstake();
            burned = unwindDiem;
            unlocked = _burnAndStartSVVV(burned);
        } else if (unwindStage == UnwindStage.SVVVCooldown) {
            uint256 beforeBalance = IERC20Minimal(VVV).balanceOf(address(this));
            IVeniceStaking(SVVV).unstake();
            recovered = IERC20Minimal(VVV).balanceOf(address(this)) - beforeBalance;
            _transfer(VVV, engine, recovered);
            unwindStage = UnwindStage.Idle;
            unwindDiem = 0;
            unwindSVVV = 0;
        } else {
            revert WrongStage();
        }
        stage = unwindStage;
    }

    function _burnAndStartSVVV(uint256 amount) private returns (uint256 unlocked) {
        uint256 beforeUnlocked = IVeniceStaking(SVVV).balanceOfUnlocked(address(this));
        IVeniceStaking(SVVV).burnDiem(amount);
        unlocked = IVeniceStaking(SVVV).balanceOfUnlocked(address(this)) - beforeUnlocked;
        unwindSVVV = unlocked;
        IVeniceStaking(SVVV).initiateUnstake(unlocked);
        unwindStage = UnwindStage.SVVVCooldown;
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory d) = token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }

    function _transfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory d) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }

    function _transferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory d) = token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!ok || (d.length != 0 && !abi.decode(d, (bool)))) revert TransferFailed();
    }
}
