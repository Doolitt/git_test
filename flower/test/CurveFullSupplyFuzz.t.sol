// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {MockNFT} from "./mocks/MockNFT.sol";

/// @notice Exercises the economic curve all the way to the protocol's full 1T supply.
contract CurveFullSupplyFuzzTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000_000 ether;
    uint256 internal constant FLOOR = 50_000_000 ether;

    ActivationManager internal manager;

    function setUp() public {
        FLOWER flower = new FLOWER(address(this));
        MockNFT nft = new MockNFT();
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
    }

    function testFullSupplyBoundaryDoesNotOverflow() public view {
        uint256 weight = manager.computeWeight(SUPPLY, SUPPLY, 730);
        assertGt(weight, manager.BASE_WEIGHT());
    }

    function testFuzzLockWeightMonotonicAcrossFullSupply(uint128 rawA, uint128 rawB) public view {
        uint256 a = bound(uint256(rawA), FLOOR, SUPPLY);
        uint256 b = bound(uint256(rawB), FLOOR, SUPPLY);
        if (a > b) (a, b) = (b, a);

        uint256 weightA = manager.computeWeight(a, 0, 365);
        uint256 weightB = manager.computeWeight(b, 0, 365);
        assertGe(weightB, weightA);
    }

    function testFuzzBurnWeightMonotonicAcrossFullSupply(uint128 rawA, uint128 rawB) public view {
        uint256 a = bound(uint256(rawA), 0, SUPPLY);
        uint256 b = bound(uint256(rawB), 0, SUPPLY);
        if (a > b) (a, b) = (b, a);

        uint256 weightA = manager.computeWeight(500_000_000 ether, a, 365);
        uint256 weightB = manager.computeWeight(500_000_000 ether, b, 365);
        assertGe(weightB, weightA);
    }

    function testFuzzDurationOrderingAtFullRange(uint128 rawLock, uint128 rawBurn) public view {
        uint256 lockAmount = bound(uint256(rawLock), FLOOR, SUPPLY);
        uint256 burnAmount = bound(uint256(rawBurn), 0, SUPPLY);

        uint256 w90 = manager.computeWeight(lockAmount, burnAmount, 90);
        uint256 w180 = manager.computeWeight(lockAmount, burnAmount, 180);
        uint256 w365 = manager.computeWeight(lockAmount, burnAmount, 365);
        uint256 w730 = manager.computeWeight(lockAmount, burnAmount, 730);

        assertGe(w180, w90);
        assertGe(w365, w180);
        assertGe(w730, w365);
    }
}
