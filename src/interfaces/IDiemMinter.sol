// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IDiemMinter {
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;
    function balanceOf(address account) external view returns (uint256);
    function cooldownDuration() external view returns (uint256);
    function stakedInfos(address account)
        external
        view
        returns (uint256 amountStaked, uint256 coolDownEnd, uint256 coolDownAmount);
}
