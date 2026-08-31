// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IActivationTransferHook} from "./IActivationTransferHook.sol";

interface IFlowerNFTActivationStatus {
    function activationHook() external view returns (IActivationTransferHook);
}
