// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title Liqpad VVV ownership router
/// @notice Isolates 70% creator revenue from the 30% protocol-owned Venice capital sent only to DiemEngine.
/// @dev Accepts accounting only from the launch hook. It has no owner, percentage switch, or EOA sweep.
contract FeeRouter {
    uint16 public constant BPS = 10_000;
    uint16 public constant CREATOR_SHARE_BPS = 7_000;
    uint16 public constant PLATFORM_SHARE_BPS = 3_000;
    address public immutable VVV;
    address public immutable factory;
    address public immutable diemEngine;
    address public hook;
    uint256 public platformAccrued;
    mapping(address token => address creator) public creatorOf;
    mapping(address creator => mapping(address token => uint256 amount)) public creatorAccrued;
    mapping(address creator => address[] tokens) private _creatorTokens;
    error OnlyFactory();
    error OnlyHook();
    error AlreadyBound();
    error InvalidAddress();
    error TokenAlreadyRegistered();
    error TransferFailed();
    event HookBound(address indexed hook);
    event LaunchRegistered(address indexed token, address indexed creator);
    event FeeAccrued(address indexed token, address indexed creator, uint256 creatorAmount, uint256 platformAmount);
    event CreatorClaimed(address indexed creator, address indexed token, uint256 amount);
    event PlatformSwept(address indexed diemEngine, uint256 amount);
    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    constructor(address vvv_, address factory_, address diemEngine_) {
        if (vvv_ == address(0) || factory_ == address(0) || diemEngine_ == address(0)) revert InvalidAddress();
        VVV = vvv_;
        factory = factory_;
        diemEngine = diemEngine_;
    }

    function bindHook(address hook_) external onlyFactory {
        if (hook != address(0)) revert AlreadyBound();
        if (hook_ == address(0)) revert InvalidAddress();
        hook = hook_;
        emit HookBound(hook_);
    }

    function registerLaunch(address token, address creator) external onlyHook {
        if (token == address(0) || creator == address(0)) revert InvalidAddress();
        if (creatorOf[token] != address(0)) revert TokenAlreadyRegistered();
        creatorOf[token] = creator;
        _creatorTokens[creator].push(token);
        emit LaunchRegistered(token, creator);
    }

    /// @notice Accounts transferred VVV as creator revenue and protocol-owned Venice capital.
    function accrue(address token, uint256 amount) external onlyHook {
        address creator = creatorOf[token];
        if (creator == address(0)) revert InvalidAddress();
        uint256 creatorAmount = amount * CREATOR_SHARE_BPS / BPS;
        uint256 platformAmount = amount - creatorAmount;
        creatorAccrued[creator][token] += creatorAmount;
        platformAccrued += platformAmount;
        emit FeeAccrued(token, creator, creatorAmount, platformAmount);
    }

    function claim(address token) public returns (uint256 amount) {
        amount = creatorAccrued[msg.sender][token];
        creatorAccrued[msg.sender][token] = 0;
        if (amount != 0) _safeTransfer(VVV, msg.sender, amount);
        emit CreatorClaimed(msg.sender, token, amount);
    }

    function claimAll() external returns (uint256 total) {
        address[] storage tokens = _creatorTokens[msg.sender];
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = creatorAccrued[msg.sender][tokens[i]];
            if (amount != 0) {
                creatorAccrued[msg.sender][tokens[i]] = 0;
                total += amount;
                emit CreatorClaimed(msg.sender, tokens[i], amount);
            }
        }
        if (total != 0) _safeTransfer(VVV, msg.sender, total);
    }

    function sweepPlatform() external returns (uint256 amount) {
        // Permissionless forwarding has one immutable destination: DiemEngine, never an owner wallet.
        amount = platformAccrued;
        platformAccrued = 0;
        if (amount != 0) _safeTransfer(VVV, diemEngine, amount);
        emit PlatformSwept(diemEngine, amount);
    }

    function creatorTokens(address creator) external view returns (address[] memory) {
        return _creatorTokens[creator];
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
