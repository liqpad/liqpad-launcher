// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";

contract MockQuoteSigner is IERC1271 {
    bytes4 private constant MAGIC_VALUE = IERC1271.isValidSignature.selector;

    function isValidSignature(bytes32, bytes calldata signature) external pure returns (bytes4) {
        return keccak256(signature) == keccak256("valid") ? MAGIC_VALUE : bytes4(0xffffffff);
    }
}
