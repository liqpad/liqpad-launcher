// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdPrecompiles} from "base-std/StdPrecompiles.sol";
import {IB20} from "base-std/interfaces/IB20.sol";
import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {B20FactoryLib} from "base-std/lib/B20FactoryLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

interface ILiqpadLaunchHook {
    function registerLaunchPool(PoolKey calldata key, address token, address creator) external;
}

interface IFeeRouterBinding {
    function bindHook(address hook) external;
}

interface ILiqpadLiquidityLocker {
    function lock(PoolKey calldata key, address token, uint256 amount, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 tokenId);
}

/// @title LiqpadFactory
/// @notice Permissionlessly creates fixed-supply, admin-less native B20 launches paired only with VVV.
/// @dev A configured launch atomically creates the B20 through Base's factory precompile, initializes its
///      zero-LP-fee Uniswap v4 pool, locks the full launch inventory as single-sided liquidity, and records metadata.
contract LiqpadFactory {
    using PoolIdLibrary for PoolKey;
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint8 public constant TOKEN_DECIMALS = 18;
    uint16 public constant HOOK_FEE_BPS = 100;
    bytes32 public constant STUB_POOL_ID = bytes32(0);
    int24 public constant TICK_SPACING = 200;

    struct Socials {
        string twitter;
        string telegram;
        string farcaster;
        string discord;
    }

    struct LaunchParams {
        string name;
        string symbol;
        bytes32 salt;
        string contractURI;
        string description;
        string logoURI;
        string website;
        Socials socials;
        address creator;
    }

    struct Profile {
        address creator;
        string name;
        string symbol;
        string contractURI;
        string description;
        string logoURI;
        string website;
        Socials socials;
        bytes32 poolId;
        uint64 launchedAt;
    }

    error EmptyName();
    error EmptySymbol();
    error EmptyContractURI();
    error ReentrantCall();
    error PredictionMismatch(address predicted, address created);
    error OnlyConfigAdmin();
    error Phase3AlreadyConfigured();
    error InvalidPhase3Config();

    event Launch(address indexed token, address indexed creator, bytes32 indexed poolId, bytes32 profileHash);
    event Phase3Configured(address indexed poolManager, address indexed hook, address indexed vvv);

    mapping(address token => Profile profile) private _profiles;
    mapping(address creator => address[] tokens) private _creatorTokens;
    mapping(address token => bool isLaunch) public isLiqpadLaunch;

    uint256 private _locked = 1;
    address public configAdmin = msg.sender;
    IPoolManager public poolManager;
    ILiqpadLaunchHook public launchHook;
    ILiqpadLiquidityLocker public liquidityLocker;
    address public VVV;
    /// @notice Protocol-level VVV quote frame: B20 per 1 VVV expressed in Uniswap tick space.
    int24 public quotedFrame;

    /// @notice One-shot deployment configuration; authority is burned immediately after use.
    function configurePhase3(
        IPoolManager manager,
        ILiqpadLaunchHook hook,
        address vvv,
        IFeeRouterBinding router,
        ILiqpadLiquidityLocker locker,
        int24 quotedFrame_
    ) external {
        if (msg.sender != configAdmin) revert OnlyConfigAdmin();
        if (address(poolManager) != address(0)) revert Phase3AlreadyConfigured();
        if (
            address(manager) == address(0) || address(hook) == address(0) || vvv == address(0)
                || address(router) == address(0) || address(locker) == address(0)
        ) {
            revert InvalidPhase3Config();
        }
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
        if (quotedFrame_ <= 0 || quotedFrame_ % TICK_SPACING != 0 || quotedFrame_ >= maxTick) {
            revert InvalidPhase3Config();
        }
        poolManager = manager;
        launchHook = hook;
        liquidityLocker = locker;
        VVV = vvv;
        quotedFrame = quotedFrame_;
        router.bindHook(address(hook));
        configAdmin = address(0);
        emit Phase3Configured(address(manager), address(hook), vvv);
    }

    modifier nonReentrant() {
        if (_locked != 1) revert ReentrantCall();
        _locked = 2;
        _;
        _locked = 1;
    }

    /// @notice Predicts the B20 address for a salt when this LiqpadFactory is the B20 deployer.
    function predictAddress(bytes32 salt) public view returns (address) {
        return _b20Factory().getB20Address(IB20Factory.B20Variant.ASSET, address(this), salt);
    }

    /// @notice Returns Base's canonical native B20 factory precompile used by production launches.
    function b20Factory() external pure returns (address) {
        return address(StdPrecompiles.B20_FACTORY);
    }

    /// @notice Returns the pool tick and single-sided B20 range for the token/VVV address ordering.
    function ticksFor(address token) public view returns (int24 poolTick, int24 tickLower, int24 tickUpper) {
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
        if (VVV < token) {
            poolTick = quotedFrame;
            tickLower = poolTick;
            tickUpper = maxTick;
        } else {
            poolTick = -quotedFrame;
            tickLower = minTick;
            tickUpper = poolTick;
        }
    }

    /// @notice Creates an admin-less B20, its B20/VVV pool, permanently locked LP, and its on-chain profile.
    /// @dev Production uses `StdPrecompiles.B20_FACTORY` (`0xB20f...0000`) with canonical base-std encodings.
    ///      The hook receives BURN_ROLE only; creator and factory retain no mint, pause, seize, or admin power.
    function createLaunch(LaunchParams calldata params) external nonReentrant returns (address token) {
        if (bytes(params.name).length == 0) revert EmptyName();
        if (bytes(params.symbol).length == 0) revert EmptySymbol();
        if (bytes(params.contractURI).length == 0) revert EmptyContractURI();

        address creator = params.creator == address(0) ? msg.sender : params.creator;
        address predicted = predictAddress(params.salt);

        bytes[] memory initCalls = new bytes[](3);
        initCalls[0] = B20FactoryLib.encodeUpdateContractURI(params.contractURI);
        initCalls[1] = B20FactoryLib.encodeUpdateSupplyCap(TOKEN_SUPPLY);
        initCalls[2] = abi.encodeCall(IB20.mint, (address(this), TOKEN_SUPPLY));

        token = _b20Factory()
            .createB20(
                IB20Factory.B20Variant.ASSET,
                params.salt,
                B20FactoryLib.encodeAssetCreateParams(params.name, params.symbol, address(this), TOKEN_DECIMALS),
                initCalls
            );
        if (token != predicted) revert PredictionMismatch(predicted, token);

        // The hook receives only BURN_ROLE, allowing it to destroy fees it already holds.
        // It receives no admin, mint, pause, freeze, seize, or metadata power.
        if (address(launchHook) != address(0)) IB20(token).grantRole(IB20(token).BURN_ROLE(), address(launchHook));
        IB20(token).renounceLastAdmin();

        bytes32 launchPoolId = STUB_POOL_ID;
        if (address(launchHook) != address(0)) {
            (Currency currency0, Currency currency1) =
                token < VVV ? (Currency.wrap(token), Currency.wrap(VVV)) : (Currency.wrap(VVV), Currency.wrap(token));
            PoolKey memory key = PoolKey(currency0, currency1, 0, TICK_SPACING, IHooks(address(launchHook)));
            (int24 poolTick, int24 tickLower, int24 tickUpper) = ticksFor(token);
            launchHook.registerLaunchPool(key, token, creator);
            poolManager.initialize(key, TickMath.getSqrtPriceAtTick(poolTick));
            _safeTransfer(token, address(liquidityLocker), TOKEN_SUPPLY);
            liquidityLocker.lock(key, token, TOKEN_SUPPLY, tickLower, tickUpper);
            launchPoolId = PoolId.unwrap(key.toId());
        }

        Profile memory profile = Profile({
            creator: creator,
            name: params.name,
            symbol: params.symbol,
            contractURI: params.contractURI,
            description: params.description,
            logoURI: params.logoURI,
            website: params.website,
            socials: params.socials,
            poolId: launchPoolId,
            launchedAt: uint64(block.timestamp)
        });

        _profiles[token] = profile;
        _creatorTokens[creator].push(token);
        isLiqpadLaunch[token] = true;
        emit Launch(token, creator, launchPoolId, _profileHash(profile));
    }

    function getProfile(address token) external view returns (Profile memory) {
        return _profiles[token];
    }

    function creatorTokens(address creator) external view returns (address[] memory) {
        return _creatorTokens[creator];
    }

    function profileHash(address token) external view returns (bytes32) {
        return _profileHash(_profiles[token]);
    }

    /// @dev Virtual only to permit a deterministic unit-test mock; production always returns the precompile.
    function _b20Factory() internal view virtual returns (IB20Factory) {
        return StdPrecompiles.B20_FACTORY;
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "B20_TRANSFER_FAILED");
    }

    function _profileHash(Profile memory profile) private pure returns (bytes32) {
        return keccak256(abi.encode(profile));
    }
}
