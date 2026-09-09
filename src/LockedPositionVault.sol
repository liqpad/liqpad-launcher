// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @title Liqpad permanently locked liquidity vault
/// @notice Mints each launch's full B20 inventory as single-sided VVV-pool liquidity and permanently holds the NFT.
/// @dev There is deliberately no NFT approval, transfer, decrease-liquidity, arbitrary-call, or withdrawal path.
contract LockedPositionVault is IERC721Receiver {
    address public immutable positionManager;
    address public immutable permit2;
    address public immutable factory;
    error OnlyPositionManager();
    error OnlyFactory();
    error InvalidToken();
    error TransferFailed();
    event PositionLocked(address indexed token, uint256 indexed tokenId, uint128 liquidity);

    constructor(address positionManager_, address permit2_, address factory_) {
        require(positionManager_ != address(0) && permit2_ != address(0) && factory_ != address(0));
        positionManager = positionManager_;
        permit2 = permit2_;
        factory = factory_;
    }

    function lock(PoolKey calldata key, address token, uint256 amount, int24 tickLower, int24 tickUpper)
        external
        returns (uint256 tokenId)
    {
        if (msg.sender != factory) revert OnlyFactory();
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        bool tokenIs0 = token == c0;
        if (
            (!tokenIs0 && token != c1) || amount == 0 || tickLower >= tickUpper || tickLower % key.tickSpacing != 0
                || tickUpper % key.tickSpacing != 0
        ) revert InvalidToken();

        _approveToken(token, permit2, amount);
        IAllowanceTransfer(permit2).approve(token, positionManager, uint160(amount), type(uint48).max);
        tokenId = IPositionManager(positionManager).nextTokenId();

        bytes memory actions =
            abi.encodePacked(bytes1(uint8(Actions.MINT_POSITION)), bytes1(uint8(Actions.SETTLE_PAIR)));
        bytes[] memory params = new bytes[](2);
        uint128 liquidity;
        (params[0], liquidity) = _mintParams(key, tokenIs0, amount, tickLower, tickUpper);
        params[1] = abi.encode(key.currency0, key.currency1);
        IPositionManager(positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        IAllowanceTransfer(permit2).approve(token, positionManager, 0, 0);
        _approveToken(token, permit2, 0);
        emit PositionLocked(token, tokenId, liquidity);
    }

    function _mintParams(PoolKey calldata key, bool tokenIs0, uint256 amount, int24 tickLower, int24 tickUpper)
        private
        view
        returns (bytes memory encoded, uint128 liquidity)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        liquidity = tokenIs0
            ? LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, amount)
            : LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, amount);
        uint128 amount0Max = tokenIs0 ? uint128(amount) : uint128(0);
        uint128 amount1Max = tokenIs0 ? uint128(0) : uint128(amount);
        encoded = abi.encode(key, tickLower, tickUpper, liquidity, amount0Max, amount1Max, address(this), bytes(""));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert OnlyPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _approveToken(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory data) = token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
