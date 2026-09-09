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
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

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
contract LiqpadFactory is EIP712 {
    using PoolIdLibrary for PoolKey;
    uint256 public constant TOKEN_SUPPLY = 1_000_000_000e18;
    uint8 public constant TOKEN_DECIMALS = 18;
    uint16 public constant HOOK_FEE_BPS = 100;
    bytes32 public constant STUB_POOL_ID = bytes32(0);
    int24 public constant TICK_SPACING = 200;
    int24 public constant MIN_QUOTED_FRAME = 80_000;
    int24 public constant MAX_QUOTED_FRAME = 200_000;
    bytes32 public constant LAUNCH_QUOTE_TYPEHASH = keccak256(
        "LaunchQuote(int24 quotedFrame,uint64 validUntil,address creator,bytes32 launchSalt)"
    );

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

    struct LaunchQuote {
        int24 quotedFrame;
        uint64 validUntil;
        address creator;
        bytes32 launchSalt;
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
    error InvalidQuoteAdmin();
    error InvalidQuoteSigner();
    error OnlyQuoteAdmin();
    error QuoteExpired();
    error InvalidQuoteCreator();
    error InvalidQuoteSalt();
    error InvalidQuotedFrame();
    error InvalidQuoteSignature();

    event Launch(address indexed token, address indexed creator, bytes32 indexed poolId, bytes32 profileHash);
    event LaunchQuoteUsed(address indexed token, int24 quotedFrame, uint64 validUntil, bytes32 quoteDigest);
    event Phase3Configured(address indexed poolManager, address indexed hook, address indexed vvv);
    event QuoteSignerUpdated(address indexed previousSigner, address indexed newSigner);

    mapping(address token => Profile profile) private _profiles;
    mapping(address creator => address[] tokens) private _creatorTokens;
    mapping(address token => bool isLaunch) public isLiqpadLaunch;

    uint256 private _locked = 1;
    address public configAdmin = msg.sender;
    address public immutable quoteAdmin;
    address public quoteSigner;
    IPoolManager public poolManager;
    ILiqpadLaunchHook public launchHook;
    ILiqpadLiquidityLocker public liquidityLocker;
    address public VVV;

    constructor(address quoteAdmin_, address quoteSigner_) EIP712("LiqpadFactory", "1") {
        if (quoteAdmin_ == address(0)) revert InvalidQuoteAdmin();
        if (quoteSigner_ == address(0)) revert InvalidQuoteSigner();
        quoteAdmin = quoteAdmin_;
        quoteSigner = quoteSigner_;
    }

    /// @notice One-shot deployment configuration; authority is burned immediately after use.
    function configurePhase3(
        IPoolManager manager,
        ILiqpadLaunchHook hook,
        address vvv,
        IFeeRouterBinding router,
        ILiqpadLiquidityLocker locker
    ) external {
        if (msg.sender != configAdmin) revert OnlyConfigAdmin();
        if (address(poolManager) != address(0)) revert Phase3AlreadyConfigured();
        if (
            address(manager) == address(0) || address(hook) == address(0) || vvv == address(0)
                || address(router) == address(0) || address(locker) == address(0)
        ) {
            revert InvalidPhase3Config();
        }
        poolManager = manager;
        launchHook = hook;
        liquidityLocker = locker;
        VVV = vvv;
        router.bindHook(address(hook));
        configAdmin = address(0);
        emit Phase3Configured(address(manager), address(hook), vvv);
    }

    /// @notice Rotates the limited-purpose signer used to authorize offline launch quotes.
    function setQuoteSigner(address newSigner) external {
        if (msg.sender != quoteAdmin) revert OnlyQuoteAdmin();
        if (newSigner == address(0)) revert InvalidQuoteSigner();
        address previousSigner = quoteSigner;
        quoteSigner = newSigner;
        emit QuoteSignerUpdated(previousSigner, newSigner);
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
    function ticksFor(address token, int24 frame)
        public
        view
        returns (int24 poolTick, int24 tickLower, int24 tickUpper)
    {
        int24 minTick = TickMath.minUsableTick(TICK_SPACING);
        int24 maxTick = TickMath.maxUsableTick(TICK_SPACING);
        if (VVV < token) {
            // currency0 = VVV, currency1 = B20. A B20-only currency1 position is below the current price.
            poolTick = frame;
            tickLower = minTick;
            tickUpper = poolTick;
        } else {
            // currency0 = B20, currency1 = VVV. A B20-only currency0 position is above the current price.
            poolTick = -frame;
            tickLower = poolTick;
            tickUpper = maxTick;
        }
    }

    /// @notice Creates an admin-less B20, its B20/VVV pool, permanently locked LP, and its on-chain profile.
    /// @dev Production uses `StdPrecompiles.B20_FACTORY` (`0xB20f...0000`) with canonical base-std encodings.
    ///      The hook receives BURN_ROLE only; creator and factory retain no mint, pause, seize, or admin power.
    function createLaunch(LaunchParams calldata params, LaunchQuote calldata quote, bytes calldata signature)
        external
        nonReentrant
        returns (address token)
    {
        if (bytes(params.name).length == 0) revert EmptyName();
        if (bytes(params.symbol).length == 0) revert EmptySymbol();
        if (bytes(params.contractURI).length == 0) revert EmptyContractURI();

        address creator = params.creator == address(0) ? msg.sender : params.creator;
        _validateQuote(quote, signature, creator, params.salt);
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
            (int24 poolTick, int24 tickLower, int24 tickUpper) = ticksFor(token, quote.quotedFrame);
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
        emit LaunchQuoteUsed(token, quote.quotedFrame, quote.validUntil, hashLaunchQuote(quote));
    }

    function hashLaunchQuote(LaunchQuote calldata quote) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    LAUNCH_QUOTE_TYPEHASH,
                    quote.quotedFrame,
                    quote.validUntil,
                    quote.creator,
                    quote.launchSalt
                )
            )
        );
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

    function _validateQuote(
        LaunchQuote calldata quote,
        bytes calldata signature,
        address creator,
        bytes32 launchSalt
    ) private view {
        if (block.timestamp > quote.validUntil) revert QuoteExpired();
        if (quote.creator != creator) revert InvalidQuoteCreator();
        if (quote.launchSalt != launchSalt) revert InvalidQuoteSalt();
        if (
            quote.quotedFrame < MIN_QUOTED_FRAME || quote.quotedFrame > MAX_QUOTED_FRAME
                || quote.quotedFrame % TICK_SPACING != 0
        ) revert InvalidQuotedFrame();
        if (!SignatureChecker.isValidSignatureNow(quoteSigner, hashLaunchQuote(quote), signature)) {
            revert InvalidQuoteSignature();
        }
    }

    function _profileHash(Profile memory profile) private pure returns (bytes32) {
        return keccak256(abi.encode(profile));
    }
}
