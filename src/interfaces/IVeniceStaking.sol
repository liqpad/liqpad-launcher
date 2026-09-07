// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVeniceStaking {
    function stake(address recipient, uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    function getDiemAmountOut(uint256 sVVVAmountToLock) external view returns (uint256);
    function mintDiem(uint256 sVVVAmountToLock, uint256 minDiemAmountOut) external;
    function burnDiem(uint256 diemAmountToBurn) external;
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnlocked(address account) external view returns (uint256);
    function cooldownDuration() external view returns (uint256);
}
