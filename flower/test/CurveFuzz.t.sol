// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {MockNFT} from "./mocks/MockNFT.sol";

contract CurveFuzzTest is Test {
    uint256 internal constant FLOOR = 50_000_000 ether;
    uint256 internal constant MAX_TEST_LOCK = 100_000_000_000 ether;
    uint256 internal constant MAX_TEST_BURN = 10_000_000_000 ether;
    uint256 internal constant LOCK_500M = 500_000_000 ether;
    uint16 internal constant DAYS_90 = 90;
    uint16 internal constant DAYS_180 = 180;
    uint16 internal constant DAYS_365 = 365;
    uint16 internal constant DAYS_730 = 730;

    ActivationManager internal manager;

    function setUp() public {
        FLOWER flower = new FLOWER(address(this));
        MockNFT nft = new MockNFT();
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
    }

    function testFuzzLockWeightIsMonotonic(uint128 seedA, uint128 seedB) public view {
        uint256 a = bound(uint256(seedA), FLOOR, MAX_TEST_LOCK);
        uint256 b = bound(uint256(seedB), FLOOR, MAX_TEST_LOCK);
        if (a > b) (a, b) = (b, a);

        uint256 weightA = manager.computeWeight(a, 0, DAYS_365);
        uint256 weightB = manager.computeWeight(b, 0, DAYS_365);
        assertLe(weightA, weightB);
    }

    function testFuzzBurnWeightIsMonotonic(uint128 seedA, uint128 seedB) public view {
        uint256 a = bound(uint256(seedA), 0, MAX_TEST_BURN);
        uint256 b = bound(uint256(seedB), 0, MAX_TEST_BURN);
        if (a > b) (a, b) = (b, a);

        uint256 weightA = manager.computeWeight(LOCK_500M, a, DAYS_365);
        uint256 weightB = manager.computeWeight(LOCK_500M, b, DAYS_365);
        assertLe(weightA, weightB);
    }

    function testFuzzLongerDurationNeverReducesWeight(uint128 lockSeed, uint128 burnSeed) public view {
        uint256 lockAmount = bound(uint256(lockSeed), FLOOR + 1_000_000 ether, MAX_TEST_LOCK);
        uint256 burnAmount = bound(uint256(burnSeed), 0, MAX_TEST_BURN);

        uint256 w90 = manager.computeWeight(lockAmount, burnAmount, DAYS_90);
        uint256 w180 = manager.computeWeight(lockAmount, burnAmount, DAYS_180);
        uint256 w365 = manager.computeWeight(lockAmount, burnAmount, DAYS_365);
        uint256 w730 = manager.computeWeight(lockAmount, burnAmount, DAYS_730);

        assertLe(w90, w180);
        assertLe(w180, w365);
        assertLe(w365, w730);
    }

    function testFuzzActivatedWeightNeverFallsBelowBase(uint128 lockSeed, uint128 burnSeed) public view {
        uint256 lockAmount = bound(uint256(lockSeed), FLOOR, MAX_TEST_LOCK);
        uint256 burnAmount = bound(uint256(burnSeed), 0, MAX_TEST_BURN);

        assertGe(manager.computeWeight(lockAmount, burnAmount, DAYS_90), manager.BASE_WEIGHT());
    }
}
