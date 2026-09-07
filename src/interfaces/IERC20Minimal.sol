// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Minimal token surface needed by later Liqpad phases.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

