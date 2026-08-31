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

contract ProtocolIntegrationTest is Test {
    uint256 internal constant MINT_PRICE = 250 ether;
    uint256 internal constant FLOOR = 50_000_000 ether;
    uint256 internal constant DEEP_LOCK = 500_000_000 ether;
    uint256 internal constant BURN_AMOUNT = 20_000_000 ether;

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
        nft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://flower/");
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
        distributor = new RewardDistributor(
            IERC20(address(usdg)), nft, IWeightProvider(address(manager)), address(manager)
        );

        nft.setActivationHook(IActivationTransferHook(address(manager)));
        manager.setRewardDistributor(IRewardDistributor(address(distributor)));

        nft.reserveMint(alice, 2); // token IDs 1 and 2
        nft.reserveMint(bob, 1); // token ID 3

        vm.prank(alice);
        flower.transfer(bob, 10_000_000_000 ether);

        vm.prank(alice);
        flower.approve(address(manager), type(uint256).max);
        vm.prank(bob);
        flower.approve(address(manager), type(uint256).max);

        usdg.mint(address(this), 10_000 ether);
        usdg.approve(address(distributor), type(uint256).max);
    }

    function testPublicMintPaysTreasuryDirectly() public {
        nft.setSaleActive(true);
        usdg.mint(alice, 1_000 ether);

        vm.startPrank(alice);
        usdg.approve(address(nft), type(uint256).max);
        nft.mint(2);
        vm.stopPrank();

        assertEq(usdg.balanceOf(treasury), 2 * MINT_PRICE);
        assertEq(nft.publicMinted(), 2);
        assertEq(nft.balanceOf(alice), 4);
        assertEq(nft.ownerOf(4), alice);
        assertEq(nft.ownerOf(5), alice);
    }

    function testActivationEscrowsFlowerAndTracksWeight() public {
        uint256 beforeBalance = flower.balanceOf(alice);

        vm.prank(alice);
        manager.activate(1, FLOOR, 90);

        assertEq(manager.weightOf(1), 0.25e18);
        assertEq(manager.totalWeight(), 0.25e18);
        assertEq(flower.balanceOf(address(manager)), FLOOR);
        assertEq(flower.balanceOf(alice), beforeBalance - FLOOR);
    }

    function testTransferResetsWeightButCannotBypassOriginalLock() public {
        vm.prank(alice);
        manager.activate(1, DEEP_LOCK, 365);

        (,, uint64 unlockAt,, uint256 oldWeight) = manager.positions(1);
        assertGt(oldWeight, 0);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(manager.weightOf(1), 0);
        assertEq(manager.totalWeight(), 0);

        (address beneficiary, uint128 amount, uint64 detachedUnlock, bool claimed) = manager.detachedLocks(1);
        assertEq(beneficiary, alice);
        assertEq(uint256(amount), DEEP_LOCK);
        assertEq(detachedUnlock, unlockAt);
        assertFalse(claimed);

        vm.prank(alice);
        vm.expectRevert(ActivationManager.LockStillCommitted.selector);
        manager.claimDetachedLock(1);

        uint256 balanceBeforeClaim = flower.balanceOf(alice);
        vm.warp(uint256(unlockAt));
        vm.prank(alice);
        manager.claimDetachedLock(1);

        assertEq(flower.balanceOf(alice), balanceBeforeClaim + DEEP_LOCK);
    }

    function testBuyerCanReactivateImmediatelyWhileSellerLockRemainsDetached() public {
        vm.prank(alice);
        manager.activate(1, DEEP_LOCK, 365);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        vm.prank(bob);
        manager.activate(1, FLOOR, 90);

        assertEq(nft.ownerOf(1), bob);
        assertEq(manager.weightOf(1), 0.25e18);
        assertEq(manager.totalWeight(), 0.25e18);

        (address beneficiary, uint128 amount,, bool claimed) = manager.detachedLocks(1);
        assertEq(beneficiary, alice);
        assertEq(uint256(amount), DEEP_LOCK);
        assertFalse(claimed);
    }

    function testPermanentBurnDevelopmentSurvivesTransfer() public {
        uint256 supplyBefore = flower.totalSupply();

        vm.prank(alice);
        manager.activate(2, FLOOR, 90);
        vm.prank(alice);
        manager.burnForDevelopment(2, BURN_AMOUNT);

        uint256 developedWeight = manager.weightOf(2);
        assertGt(developedWeight, 0.25e18);
        assertEq(manager.permanentBurned(2), BURN_AMOUNT);
        assertEq(flower.totalSupply(), supplyBefore - BURN_AMOUNT);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 2);
        assertEq(manager.weightOf(2), 0);

        vm.prank(bob);
        manager.activate(2, FLOOR, 90);

        assertEq(manager.permanentBurned(2), BURN_AMOUNT);
        assertEq(manager.weightOf(2), manager.computeWeight(FLOOR, BURN_AMOUNT, 90));
    }

    function testRewardsCheckpointSellerAndDoNotLeakToBuyer() public {
        vm.prank(alice);
        manager.activate(1, FLOOR, 90);

        distributor.fund(1_000 ether);
        assertEq(distributor.pending(1), 1_000 ether);

        vm.prank(alice);
        nft.transferFrom(alice, bob, 1);

        assertEq(distributor.claimable(alice), 1_000 ether);
        assertEq(distributor.pending(1), 0);

        vm.prank(bob);
        manager.activate(1, FLOOR, 90);
        distributor.fund(500 ether);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;

        vm.prank(bob);
        distributor.claim(ids);
        vm.prank(alice);
        distributor.claimCredits();

        assertEq(usdg.balanceOf(alice), 1_000 ether);
        assertEq(usdg.balanceOf(bob), 500 ether);
        assertEq(distributor.totalFunded(), 1_500 ether);
        assertEq(distributor.totalClaimed(), 1_500 ether);
        assertEq(usdg.balanceOf(address(distributor)), 0);
    }

    function testMinimumCommitmentKeepsWeightUntilExplicitWithdrawal() public {
        vm.prank(alice);
        manager.activate(1, FLOOR, 90);

        (,, uint64 unlockAt,,) = manager.positions(1);
        vm.warp(uint256(unlockAt) + 1 days);

        // Current v0.1 semantics: expiry is the earliest withdrawal date, not an automatic weight expiry.
        assertEq(manager.weightOf(1), 0.25e18);
        assertEq(manager.totalWeight(), 0.25e18);

        distributor.fund(100 ether);

        vm.prank(alice);
        manager.withdraw(1);
        assertEq(manager.weightOf(1), 0);
        assertEq(manager.totalWeight(), 0);

        vm.prank(alice);
        distributor.claimCredits();
        assertEq(usdg.balanceOf(alice), 100 ether);
    }

    function testFundingWithoutActiveWeightReverts() public {
        vm.expectRevert(RewardDistributor.NoActiveWeight.selector);
        distributor.fund(1 ether);
    }

    function testClaimBatchIsBounded() public {
        uint256[] memory ids = new uint256[](RewardDistributor.MAX_CLAIM_BATCH() + 1);
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ClaimBatchTooLarge.selector);
        distributor.claim(ids);
    }
}
