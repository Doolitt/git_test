// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardDistributorStatus {
    function ACTIVATION_MANAGER() external view returns (address);
    function NFT() external view returns (address);
    function WEIGHT_PROVIDER() external view returns (address);
}
