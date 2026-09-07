// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IB20Factory} from "base-std/interfaces/IB20Factory.sol";
import {MockB20} from "./MockB20.sol";

contract MockB20Factory is IB20Factory {
    mapping(address token => bool initialized) public initialized;

    function createB20(B20Variant variant, bytes32 salt, bytes calldata params, bytes[] calldata initCalls)
        external
        payable
        returns (address token)
    {
        require(variant == B20Variant.ASSET);
        B20AssetCreateParams memory decoded = abi.decode(params, (B20AssetCreateParams));
        token = address(new MockB20{salt: _deploymentSalt(msg.sender, salt)}());
        MockB20(token).initialize(decoded.name, decoded.symbol, decoded.initialAdmin, decoded.decimals);

        for (uint256 i; i < initCalls.length; ++i) {
            (bool success, bytes memory result) = token.call(initCalls[i]);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
        initialized[token] = true;
    }

    function getB20Address(B20Variant variant, address sender, bytes32 salt) external view returns (address) {
        require(variant == B20Variant.ASSET);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff), address(this), _deploymentSalt(sender, salt), keccak256(type(MockB20).creationCode)
            )
        );
        return address(uint160(uint256(hash)));
    }

    function isB20(address token) external view returns (bool) {
        return initialized[token];
    }

    function isB20Initialized(address token) external view returns (bool) {
        return initialized[token];
    }

    function _deploymentSalt(address sender, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(sender, salt));
    }
}

