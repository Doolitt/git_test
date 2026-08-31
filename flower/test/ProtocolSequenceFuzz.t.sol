// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {FlowerNFT} from "../src/FlowerNFT.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {IActivationTransferHook} from "../src/interfaces/IActivationTransferHook.sol";
import {IRewardDistributor} from "../src/interfaces/IRewardDistributor.sol";
import {IWeightProvider} from "../src/interfaces/IWeightProvider.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Randomizes the economically sensitive secondary-market lifecycle.
contract ProtocolSequenceFuzzTest is Test {
    uint256 internal constant FLOOR = 50_000_000 ether;
    uint16 internal constant DAYS_365 = 365;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal treasury = address(0x7777);

    FLOWER internal flower;
    MockERC20 internal usdg;
    FlowerNFT internal nft;
    ActivationManager internal manager;
    RewardDistributor internal distributor;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG");
        flower = new FLOWER(alice);
        nft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, 250 ether, "ipfs://flower/");
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
        distributor = new RewardDistributor(IERC20(address(usdg)), nft, IWeightProvider(address(manager)), address(manager));

        nft.setActivationHook(IActivationTransferHook(address(manager)));
        manager.setRewardDistributor(IRewardDistributor(address(distributor)));
        manager.enableActivation();
        nft.reserveMint(alice, 1);

        vm.prank(alice);
        flower.transfer(bob, 100_000_000_000 ether);
        vm.prank(alice);
        flower.approve(address(manager), type(uint256).max);
        vm.prank(bob);
        flower.approve(address(manager), type(uint256).max);

        usdg.mint(address(this), 2_000_000 ether);
        usdg.approve(address(distributor), type(uint256).max);
    }

    function testFuzzTransferReactivateBurnAndClaim(
        uint96 rawLockA,
        uint96 rawLockB,
        uint96 rawBurnA,
        uint96 rawBurnB,
        uint96 rawRewardA,
        uint96 rawRewardB
    ) public {
        uint256 lockA = bound(uint256(rawLockA), FLOOR, 20_000_000_000 ether);
        uint256 lockB = bound(uint256(rawLockB), FLOOR, 20_000_000_000 ether);
        uint256 burnA = bound(uint256(rawBurnA), 0, 1_000_000_000 ether);
        uint256 burnB = bound(uint256(rawBurnB), 0, 1_000_000_000 ether);
        uint256 rewardA = bound(uint256(rawRewardA), 1 ether, 500_000 ether);
        uint256 rewardB = bound(uint256(rawRewardB), 1 ether, 500_000 ether);

        uint256 initialSupply = flower.totalSupply();

        vm.prank(alice);
        manager.activate(1, lockA, DAYS_365);
        if (burnA != 0) {
            vm.prank(alice);
            manager.burnForDevelopment(1, burnA);
        }
        distributor.fund(rewardA);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);
        assertEq(manager.weightOf(1), 0);

        vm.prank(bob);
        manager.activate(1, lockB, DAYS_365);
        if (burnB != 0) {
            vm.prank(bob);
            manager.burnForDevelopment(1, burnB);
        }
        distributor.fund(rewardB);

        uint256 expectedBurn = burnA + burnB;
        assertEq(manager.permanentBurned(1), expectedBurn);
        assertEq(flower.totalSupply(), initialSupply - expectedBurn);
        assertEq(manager.weightOf(1), manager.computeWeight(lockB, expectedBurn, DAYS_365));
        assertEq(manager.totalWeight(), manager.weightOf(1));

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(bob);
        distributor.claim(ids);
        vm.prank(alice);
        distributor.claimCredits();

        uint256 alicePaid = usdg.balanceOf(alice);
        uint256 bobPaid = usdg.balanceOf(bob);
        assertApproxEqAbs(alicePaid, rewardA, 16);
        assertApproxEqAbs(bobPaid, rewardB, 16);
        assertEq(distributor.totalClaimed(), alicePaid + bobPaid);
        assertLe(distributor.totalClaimed(), rewardA + rewardB);
        assertEq(usdg.balanceOf(address(distributor)), distributor.accountedLiability());
        assertLe(distributor.accountedLiability(), 32);
    }
}
