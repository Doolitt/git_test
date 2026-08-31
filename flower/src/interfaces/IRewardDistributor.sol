// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IRewardDistributor {
    /// @notice Checkpoint a token at its old weight before the manager installs a new weight.
    function onWeightChange(
        uint256 tokenId,
        address beneficiary,
        uint256 oldWeight,
        uint256 newWeight
    ) external;
}
