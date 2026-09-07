// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVeniceAdapter {
    enum UnwindStage {
        Idle,
        DiemCooldown,
        SVVVCooldown
    }
    function VVV() external view returns (address);
    function SVVV() external view returns (address);
    function DIEM() external view returns (address);
    function stakeVVV(uint256 amount) external returns (uint256 sVVVReceived);
    function unlockedSVVV() external view returns (uint256);
    function quoteDiem(uint256 sVVVAmount) external view returns (uint256);
    function mintDiem(uint256 sVVVAmount, uint256 minDiemOut) external returns (uint256 diemOut);
    function stakeDiem(uint256 amount) external;
    function beginUnwind(uint256 diemAmount) external;
    function finalizeUnwind()
        external
        returns (UnwindStage stage, uint256 diemBurned, uint256 sVVVUnlocked, uint256 vvvRecovered);
    function unwindStage() external view returns (UnwindStage);
}
