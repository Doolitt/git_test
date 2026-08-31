// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWeightProvider {
    function totalWeight() external view returns (uint256);
    function weightOf(uint256 tokenId) external view returns (uint256);
}
