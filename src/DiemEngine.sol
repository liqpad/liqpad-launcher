// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IVeniceAdapter} from "./interfaces/IVeniceAdapter.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";

/// @title Liqpad protocol-owned Venice capital engine
/// @notice Permissionlessly converts Liqpad's 30% VVV allocation into sVVV and DIEM for protocol inference.
/// @dev Owner controls bounded harvest policy, pause, and exceptional timelocked unwind. The engine is not
///      trustless, but owner authority does not reach creator claims, launch rules, or locked LP.
contract DiemEngine {
    uint16 public constant BPS = 10_000;
    uint16 public constant DEFAULT_RESERVE_BPS = 500;
    uint16 public constant MAX_RESERVE_BPS = 2_000;
    uint16 public constant DEFAULT_MIN_OUT_BPS = 9_900;

    address public owner;
    address public immutable VVV;
    IVeniceAdapter public immutable adapter;
    uint16 public reserveBps = DEFAULT_RESERVE_BPS;
    uint16 public minOutBps = DEFAULT_MIN_OUT_BPS;
    uint256 public minMintSVVV;
    uint256 public unwindDelay;
    bool public autoStakeDiem;
    bool public harvestPaused;

    uint256 public vvvReceived;
    uint256 public vvvStaked;
    uint256 public sVVVLocked;
    uint256 public diemMinted;
    uint256 public diemStaked;
    uint256 public diemLiquid;
    uint256 public accountedLiquidVVV;

    uint256 public pendingUnwindDiem;
    uint256 public unwindReadyAt;
    bool public unwindStarted;
    uint256 private _locked = 1;

    error OnlyOwner();
    error ReentrantCall();
    error HarvestPaused();
    error ReserveTooHigh();
    error InvalidConfig();
    error UnwindPending();
    error NoUnwind();
    error TimelockActive();
    error InvalidUnwindAmount();
    error TransferFailed();
    event Harvest(uint256 vvvReceived, uint256 vvvStaked, uint256 sVVVLocked, uint256 diemMinted, uint256 diemStaked);
    event UnwindBegun(uint256 diemAmount, uint256 readyAt);
    event UnwindProgressed(
        IVeniceAdapter.UnwindStage stage, uint256 diemBurned, uint256 sVVVUnlocked, uint256 vvvRecovered
    );
    event HarvestPausedSet(bool paused);

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }
    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address owner_, IVeniceAdapter adapter_, uint256 minMintSVVV_, uint256 unwindDelay_, bool autoStake_) {
        if (owner_ == address(0) || address(adapter_) == address(0) || minMintSVVV_ == 0) revert InvalidConfig();
        owner = owner_;
        adapter = adapter_;
        VVV = adapter_.VVV();
        minMintSVVV = minMintSVVV_;
        unwindDelay = unwindDelay_;
        autoStakeDiem = autoStake_;
    }

    /// @notice Permissionlessly processes protocol VVV while preserving the configured liquid buffer.
    function harvest() external nonReentrant {
        _harvest();
    }

    function compound() external nonReentrant {
        _harvest();
    }

    function _harvest() private {
        if (harvestPaused) revert HarvestPaused();
        uint256 liquid = IERC20Minimal(VVV).balanceOf(address(this));
        if (liquid > accountedLiquidVVV) vvvReceived += liquid - accountedLiquidVVV;
        uint256 reserve = vvvReceived * reserveBps / BPS;
        if (liquid > reserve) {
            uint256 amount = liquid - reserve;
            _approve(VVV, address(adapter), amount);
            uint256 received = adapter.stakeVVV(amount);
            _approve(VVV, address(adapter), 0);
            vvvStaked += amount;
            accountedLiquidVVV = reserve;
            received;
        } else {
            accountedLiquidVVV = liquid;
        }

        uint256 unlocked = adapter.unlockedSVVV();
        if (unlocked >= minMintSVVV) {
            uint256 quote = adapter.quoteDiem(unlocked);
            uint256 minted = adapter.mintDiem(unlocked, quote * minOutBps / BPS);
            sVVVLocked += unlocked;
            diemMinted += minted;
            if (autoStakeDiem && minted != 0) {
                adapter.stakeDiem(minted);
                diemStaked += minted;
            } else {
                diemLiquid += minted;
            }
        }
        emit Harvest(vvvReceived, vvvStaked, sVVVLocked, diemMinted, diemStaked);
    }

    /// @notice Schedules exceptional Venice capital recovery; not a routine owner cash-out function.
    function beginUnwind(uint256 diemAmount) external onlyOwner nonReentrant {
        if (pendingUnwindDiem != 0) revert UnwindPending();
        if (diemAmount == 0 || (diemAmount > diemStaked && diemAmount > diemLiquid)) revert InvalidUnwindAmount();
        pendingUnwindDiem = diemAmount;
        unwindReadyAt = block.timestamp + unwindDelay;
        emit UnwindBegun(diemAmount, unwindReadyAt);
    }

    function finalizeUnwind() external onlyOwner nonReentrant {
        if (pendingUnwindDiem == 0) revert NoUnwind();
        if (block.timestamp < unwindReadyAt) revert TimelockActive();
        if (!unwindStarted) {
            if (pendingUnwindDiem <= diemStaked) diemStaked -= pendingUnwindDiem;
            else diemLiquid -= pendingUnwindDiem;
            adapter.beginUnwind(pendingUnwindDiem);
            unwindStarted = true;
            emit UnwindProgressed(adapter.unwindStage(), 0, 0, 0);
            return;
        }
        (IVeniceAdapter.UnwindStage stage, uint256 burned, uint256 unlocked, uint256 recovered) =
            adapter.finalizeUnwind();
        if (burned != 0) {
            diemMinted -= burned;
            sVVVLocked -= unlocked;
        }
        if (recovered != 0) {
            accountedLiquidVVV += recovered;
            vvvStaked -= recovered;
        }
        if (stage == IVeniceAdapter.UnwindStage.Idle) {
            pendingUnwindDiem = 0;
            unwindReadyAt = 0;
            unwindStarted = false;
        }
        emit UnwindProgressed(stage, burned, unlocked, recovered);
    }

    function setHarvestPaused(bool paused) external onlyOwner {
        harvestPaused = paused;
        emit HarvestPausedSet(paused);
    }

    function setReserveBps(uint16 bps) external onlyOwner {
        if (bps > MAX_RESERVE_BPS) revert ReserveTooHigh();
        reserveBps = bps;
    }

    function setAutoStakeDiem(bool enabled) external onlyOwner {
        autoStakeDiem = enabled;
    }

    function setMinMintSVVV(uint256 amount) external onlyOwner {
        if (amount == 0) revert InvalidConfig();
        minMintSVVV = amount;
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert InvalidConfig();
        owner = next;
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
