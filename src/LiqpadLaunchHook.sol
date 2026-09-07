// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {FeeRouter} from "./FeeRouter.sol";

interface IBurnableB20 {
    function burn(uint256 amount) external;
}

/// @title Liqpad immutable B20/VVV market hook
/// @notice Admits only factory-created B20/VVV pools, burns collected B20, and routes VVV for 70/30 accounting.
/// @dev Pool LP fee is zero. This contract has no owner, fee switch, alternate pair, or fee-withdraw path.
contract LiqpadLaunchHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeCast for uint256;
    uint16 public constant BPS = 10_000;
    uint16 public constant FEE_BPS = 100;
    uint24 public constant POOL_LP_FEE = 0;
    int24 public constant TICK_SPACING = 200;
    address public immutable VVV;
    address public immutable factory;
    FeeRouter public immutable feeRouter;

    struct LaunchPool {
        address token;
        address creator;
        bool registered;
        bool initialized;
    }
    mapping(PoolId id => LaunchPool launch) public launchPools;
    error OnlyFactory();
    error InvalidLaunchPool();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error UnauthorizedInitializer();
    error ExactOutputDisabled();
    error FeeTooLarge();
    event LaunchPoolRegistered(PoolId indexed poolId, address indexed token, address indexed creator);
    event LaunchPoolInitialized(PoolId indexed poolId);
    event B20Burned(address indexed token, uint256 amount);
    event VVVFeeCollected(address indexed token, uint256 amount);

    constructor(IPoolManager manager_, address vvv_, address factory_, FeeRouter feeRouter_) BaseHook(manager_) {
        if (vvv_ == address(0) || factory_ == address(0) || address(feeRouter_) == address(0)) {
            revert InvalidLaunchPool();
        }
        VVV = vvv_;
        factory = factory_;
        feeRouter = feeRouter_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function registerLaunchPool(PoolKey calldata key, address token, address creator) external {
        if (msg.sender != factory) revert OnlyFactory();
        if (!_validKey(key, token) || creator == address(0)) revert InvalidLaunchPool();
        PoolId id = key.toId();
        if (launchPools[id].registered) revert PoolAlreadyRegistered();
        launchPools[id] = LaunchPool(token, creator, true, false);
        feeRouter.registerLaunch(token, creator);
        emit LaunchPoolRegistered(id, token, creator);
    }

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        PoolId id = key.toId();
        LaunchPool storage launch = launchPools[id];
        if (!launch.registered) revert PoolNotRegistered();
        if (sender != factory) revert UnauthorizedInitializer();
        if (!_validKey(key, launch.token)) revert InvalidLaunchPool();
        launch.initialized = true;
        emit LaunchPoolInitialized(id);
        return IHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        LaunchPool memory launch = _checkedLaunch(key);
        if (params.amountSpecified >= 0) revert ExactOutputDisabled();
        uint256 fee = uint256(-params.amountSpecified) * FEE_BPS / BPS;
        if (fee > uint256(uint128(type(int128).max))) revert FeeTooLarge();
        _collect(params.zeroForOne ? key.currency0 : key.currency1, launch.token, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        LaunchPool memory launch = _checkedLaunch(key);
        Currency input = params.zeroForOne ? key.currency0 : key.currency1;
        if (Currency.unwrap(input) == VVV) return (IHooks.afterSwap.selector, 0);
        Currency output = params.zeroForOne ? key.currency1 : key.currency0;
        int128 raw = params.zeroForOne ? delta.amount1() : delta.amount0();
        uint256 gross = raw < 0 ? uint256(uint128(-raw)) : uint256(uint128(raw));
        uint256 fee = gross * FEE_BPS / BPS;
        if (fee > uint256(uint128(type(int128).max))) revert FeeTooLarge();
        _collect(output, launch.token, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    function _collect(Currency currency, address token, uint256 amount) private {
        if (amount == 0) return;
        if (Currency.unwrap(currency) == VVV) {
            poolManager.take(currency, address(feeRouter), amount);
            feeRouter.accrue(token, amount);
            emit VVVFeeCollected(token, amount);
        } else {
            // B20 is destroyed here before any split; FeeRouter never custodies launch-token fees.
            poolManager.take(currency, address(this), amount);
            IBurnableB20(token).burn(amount);
            emit B20Burned(token, amount);
        }
    }

    function _checkedLaunch(PoolKey calldata key) private view returns (LaunchPool memory launch) {
        launch = launchPools[key.toId()];
        if (!launch.registered || !launch.initialized || !_validKey(key, launch.token)) revert PoolNotRegistered();
    }

    function _validKey(PoolKey calldata key, address token) private view returns (bool) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool pair = (c0 == VVV && c1 == token) || (c1 == VVV && c0 == token);
        return pair && token != address(0) && token != VVV && key.fee == POOL_LP_FEE && key.tickSpacing == TICK_SPACING
            && address(key.hooks) == address(this);
    }
}
