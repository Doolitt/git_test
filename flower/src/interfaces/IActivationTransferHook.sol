// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Hook called by FlowerNFT after a secondary transfer.
/// @dev The activation manager uses this to zero temporary reward weight and
///      detach the seller's still-locked FLOWER position.
interface IActivationTransferHook {
    function onNftTransfer(uint256 tokenId, address from, address to) external;
}
