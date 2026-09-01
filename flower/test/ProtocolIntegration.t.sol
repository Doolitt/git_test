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
    uint256 internal constant BASE_WEIGHT = 0.20e18;
    uint256 internal constant REWARD_100 = 100 ether;
    uint256 internal constant REWARD_500 = 500 ether;
    uint256 internal constant REWARD_1000 = 1_000 ether;
    uint16 internal constant DAYS_90 = 90;
    uint16 internal constant DAYS_365 = 365;

    uint256 internal constant TOKEN_ONE = 1;
    uint256 internal constant TOKEN_TWO = 2;
    uint256 internal constant TOKEN_THREE = 3;

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
        distributor =
            new RewardDistributor(IERC20(address(usdg)), nft, IWeightProvider(address(manager)), address(manager));

        nft.setActivationHook(IActivationTransferHook(address(manager)));
        manager.setRewardDistributor(IRewardDistributor(address(distributor)));
        manager.enableActivation();

        nft.reserveMint(alice, 2);
        nft.reserveMint(bob, 1);

        vm.prank(alice);
        assertTrue(flower.transfer(bob, 10_000_000_000 ether));

        vm.prank(alice);
        assertTrue(flower.approve(address(manager), type(uint256).max));
        vm.prank(bob);
        assertTrue(flower.approve(address(manager), type(uint256).max));

        usdg.mint(address(this), 10_000 ether);
        assertTrue(usdg.approve(address(distributor), type(uint256).max));
    }

    function testReserveFinalizationLocksAllocationAndPublicMintPaysTreasury() public {
        _completeReserveAllocation();
        nft.finalizeReserveMinting();
        assertEq(nft.reservedMinted(), nft.RESERVED_SUPPLY());
        assertTrue(nft.reserveMintingFinalized());

        vm.expectRevert(FlowerNFT.ReserveAlreadyFinalized.selector);
        nft.reserveMint(alice, 1);

        nft.setSaleActive(true);
        usdg.mint(alice, REWARD_1000);

        vm.startPrank(alice);
        assertTrue(usdg.approve(address(nft), type(uint256).max));
        nft.mint(2);
        vm.stopPrank();

        assertEq(usdg.balanceOf(treasury), 2 * MINT_PRICE);
        assertEq(nft.publicMinted(), 2);
        assertEq(nft.ownerOf(nft.RESERVED_SUPPLY() + 1), alice);
        assertEq(nft.ownerOf(nft.RESERVED_SUPPLY() + 2), alice);
    }

    function testPublicSaleCannotOpenBeforeReserveFinalized() public {
        vm.expectRevert(FlowerNFT.ReserveNotFinalized.selector);
        nft.setSaleActive(true);
    }

    function testReserveCannotFinalizeWhileAllocationIsIncomplete() public {
        vm.expectRevert(FlowerNFT.ReserveIncomplete.selector);
        nft.finalizeReserveMinting();
    }

    function testMetadataFreezeIsPermanent() public {
        nft.setBaseURI("ipfs://final/");
        nft.freezeMetadata();
        assertTrue(nft.metadataFrozen());

        vm.expectRevert(FlowerNFT.MetadataIsFrozen.selector);
        nft.setBaseURI("ipfs://changed/");
    }

    function testActivationCannotStartBeforeOneWayWiring() public {
        FlowerNFT freshNft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://fresh/");
        ActivationManager freshManager = new ActivationManager(address(this), freshNft, IFLOWER(address(flower)));
        freshNft.reserveMint(alice, 1);

        vm.prank(alice);
        assertTrue(flower.approve(address(freshManager), type(uint256).max));

        vm.prank(alice);
        vm.expectRevert(ActivationManager.ActivationNotEnabled.selector);
        freshManager.activate(1, FLOOR, DAYS_90);
    }

    function testEnableActivationRequiresInstalledHook() public {
        FlowerNFT freshNft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://fresh/");
        ActivationManager freshManager = new ActivationManager(address(this), freshNft, IFLOWER(address(flower)));
        RewardDistributor freshDistributor = new RewardDistributor(
            IERC20(address(usdg)), freshNft, IWeightProvider(address(freshManager)), address(freshManager)
        );
        freshManager.setRewardDistributor(IRewardDistributor(address(freshDistributor)));

        vm.expectRevert(ActivationManager.HookNotInstalled.selector);
        freshManager.enableActivation();
    }

    function testRejectsDistributorBoundToDifferentManager() public {
        FlowerNFT freshNft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://fresh/");
        ActivationManager freshManager = new ActivationManager(address(this), freshNft, IFLOWER(address(flower)));
        ActivationManager wrongManager = new ActivationManager(address(this), freshNft, IFLOWER(address(flower)));
        RewardDistributor wrongDistributor = new RewardDistributor(
            IERC20(address(usdg)), freshNft, IWeightProvider(address(wrongManager)), address(wrongManager)
        );
        freshNft.setActivationHook(IActivationTransferHook(address(freshManager)));
        vm.expectRevert(ActivationManager.InvalidRewardDistributor.selector);
        freshManager.setRewardDistributor(IRewardDistributor(address(wrongDistributor)));
    }

    function testRewardDistributorMustBeAContract() public {
        FlowerNFT freshNft = new FlowerNFT(address(this), IERC20(address(usdg)), treasury, MINT_PRICE, "ipfs://fresh/");
        ActivationManager freshManager = new ActivationManager(address(this), freshNft, IFLOWER(address(flower)));
        vm.expectRevert(ActivationManager.InvalidRewardDistributor.selector);
        freshManager.setRewardDistributor(IRewardDistributor(alice));
    }

    function testActivationEscrowsFlowerAndTracksWeight() public {
        uint256 beforeBalance = flower.balanceOf(alice);
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        assertEq(manager.weightOf(TOKEN_ONE), BASE_WEIGHT);
        assertEq(manager.totalWeight(), BASE_WEIGHT);
        assertEq(flower.balanceOf(address(manager)), FLOOR);
        assertEq(flower.balanceOf(alice), beforeBalance - FLOOR);
    }

    function testActivationFailureRollsBackState() public {
        vm.prank(bob);
        assertTrue(flower.approve(address(manager), 0));
        vm.prank(bob);
        vm.expectRevert();
        manager.activate(TOKEN_THREE, FLOOR, DAYS_90);
        assertEq(manager.weightOf(TOKEN_THREE), 0);
        assertEq(manager.totalWeight(), 0);
        assertEq(flower.balanceOf(address(manager)), 0);
    }

    function testSelfTransferDoesNotDetachActivation() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, DEEP_LOCK, DAYS_365);
        uint256 weightBefore = manager.weightOf(TOKEN_ONE);
        uint256 detachedIdBefore = manager.nextDetachedLockId();
        vm.prank(alice);
        nft.transferFrom(alice, alice, TOKEN_ONE);
        assertEq(manager.weightOf(TOKEN_ONE), weightBefore);
        assertEq(manager.totalWeight(), weightBefore);
        assertEq(manager.nextDetachedLockId(), detachedIdBefore);
    }

    function testTransferResetsWeightButCannotBypassOriginalLock() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, DEEP_LOCK, DAYS_365);
        (,, uint64 unlockAt,, uint256 oldWeight) = manager.positions(TOKEN_ONE);
        assertGt(oldWeight, 0);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ONE);
        assertEq(manager.weightOf(TOKEN_ONE), 0);
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
        manager.activate(TOKEN_ONE, DEEP_LOCK, DAYS_365);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ONE);
        vm.prank(bob);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        assertEq(nft.ownerOf(TOKEN_ONE), bob);
        assertEq(manager.weightOf(TOKEN_ONE), BASE_WEIGHT);
        assertEq(manager.totalWeight(), BASE_WEIGHT);
        (address beneficiary, uint128 amount,, bool claimed) = manager.detachedLocks(1);
        assertEq(beneficiary, alice);
        assertEq(uint256(amount), DEEP_LOCK);
        assertFalse(claimed);
    }

    function testIncreaseLockRenewsFullCommitmentPeriod() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        (,, uint64 originalUnlock,,) = manager.positions(TOKEN_ONE);
        vm.warp(block.timestamp + 80 days);
        vm.prank(alice);
        manager.increaseLock(TOKEN_ONE, FLOOR);
        (, uint128 locked, uint64 renewedUnlock,, uint256 newWeight) = manager.positions(TOKEN_ONE);
        assertEq(uint256(locked), 2 * FLOOR);
        assertGt(renewedUnlock, originalUnlock);
        assertEq(uint256(renewedUnlock), block.timestamp + 90 days);
        assertGt(newWeight, BASE_WEIGHT);
        vm.warp(uint256(originalUnlock) + 1);
        vm.prank(alice);
        vm.expectRevert(ActivationManager.LockStillCommitted.selector);
        manager.withdraw(TOKEN_ONE);
        vm.warp(uint256(renewedUnlock));
        vm.prank(alice);
        manager.withdraw(TOKEN_ONE);
        assertEq(manager.totalWeight(), 0);
    }

    function testDurationCanOnlyExtendAndRestartsCommitment() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, DEEP_LOCK, DAYS_90);
        (,, uint64 originalUnlock,, uint256 oldWeight) = manager.positions(TOKEN_ONE);
        vm.warp(block.timestamp + 10 days);
        vm.prank(alice);
        manager.extendDuration(TOKEN_ONE, DAYS_365);
        (,, uint64 extendedUnlock, uint16 durationDays, uint256 newWeight) = manager.positions(TOKEN_ONE);
        assertEq(durationDays, DAYS_365);
        assertEq(uint256(extendedUnlock), block.timestamp + 365 days);
        assertGt(extendedUnlock, originalUnlock);
        assertGt(newWeight, oldWeight);
        vm.prank(alice);
        vm.expectRevert(ActivationManager.DurationNotExtended.selector);
        manager.extendDuration(TOKEN_ONE, 180);
    }

    function testTopUpCheckpointsRewardsBeforeNewWeightApplies() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        distributor.fund(REWARD_100);
        vm.prank(alice);
        manager.increaseLock(TOKEN_ONE, FLOOR);
        assertEq(distributor.claimable(alice), REWARD_100);
        distributor.fund(REWARD_100);
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ONE;
        vm.prank(alice);
        distributor.claim(ids);
        uint256 expectedPaid = 2 * REWARD_100 - 1;
        assertEq(usdg.balanceOf(alice), expectedPaid);
        assertEq(usdg.balanceOf(address(distributor)), 1);
        assertEq(distributor.accountedLiability(), 1);
    }

    function testTwoHolderRewardClaimsRemainSolventWithUnequalWeights() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        vm.prank(bob);
        manager.activate(TOKEN_THREE, DEEP_LOCK, DAYS_365);
        uint256 funded = 777 ether;
        distributor.fund(funded);
        uint256[] memory aliceIds = new uint256[](1);
        aliceIds[0] = TOKEN_ONE;
        uint256[] memory bobIds = new uint256[](1);
        bobIds[0] = TOKEN_THREE;
        vm.prank(alice);
        distributor.claim(aliceIds);
        vm.prank(bob);
        distributor.claim(bobIds);
        uint256 totalPaid = usdg.balanceOf(alice) + usdg.balanceOf(bob);
        uint256 liability = distributor.accountedLiability();
        assertLe(totalPaid, funded);
        assertEq(distributor.totalClaimed(), totalPaid);
        assertEq(distributor.totalFunded(), funded);
        assertEq(usdg.balanceOf(address(distributor)), liability);
        assertEq(totalPaid + liability, funded);
    }

    function testPermanentBurnDevelopmentSurvivesTransfer() public {
        uint256 supplyBefore = flower.totalSupply();
        vm.prank(alice);
        manager.activate(TOKEN_TWO, FLOOR, DAYS_90);
        vm.prank(alice);
        manager.burnForDevelopment(TOKEN_TWO, BURN_AMOUNT);
        uint256 developedWeight = manager.weightOf(TOKEN_TWO);
        assertGt(developedWeight, BASE_WEIGHT);
        assertEq(manager.permanentBurned(TOKEN_TWO), BURN_AMOUNT);
        assertEq(flower.totalSupply(), supplyBefore - BURN_AMOUNT);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_TWO);
        assertEq(manager.weightOf(TOKEN_TWO), 0);
        vm.prank(bob);
        manager.activate(TOKEN_TWO, FLOOR, DAYS_90);
        assertEq(manager.permanentBurned(TOKEN_TWO), BURN_AMOUNT);
        assertEq(manager.weightOf(TOKEN_TWO), manager.computeWeight(FLOOR, BURN_AMOUNT, DAYS_90));
    }

    function testRewardsCheckpointSellerAndDoNotLeakToBuyer() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        distributor.fund(REWARD_1000);
        assertEq(distributor.pending(TOKEN_ONE), REWARD_1000);
        vm.prank(alice);
        nft.transferFrom(alice, bob, TOKEN_ONE);
        assertEq(distributor.claimable(alice), REWARD_1000);
        assertEq(distributor.pending(TOKEN_ONE), 0);
        vm.prank(bob);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        distributor.fund(REWARD_500);
        uint256[] memory ids = new uint256[](1);
        ids[0] = TOKEN_ONE;
        vm.prank(bob);
        distributor.claim(ids);
        vm.prank(alice);
        distributor.claimCredits();
        assertEq(usdg.balanceOf(alice), REWARD_1000);
        assertEq(usdg.balanceOf(bob), REWARD_500);
        assertEq(distributor.totalFunded(), REWARD_1000 + REWARD_500);
        assertEq(distributor.totalClaimed(), REWARD_1000 + REWARD_500);
        assertEq(distributor.accountedLiability(), 0);
        assertEq(usdg.balanceOf(address(distributor)), 0);
    }

    function testMinimumCommitmentKeepsWeightUntilExplicitWithdrawal() public {
        vm.prank(alice);
        manager.activate(TOKEN_ONE, FLOOR, DAYS_90);
        (,, uint64 unlockAt,,) = manager.positions(TOKEN_ONE);
        vm.warp(uint256(unlockAt) + 1 days);
        assertEq(manager.weightOf(TOKEN_ONE), BASE_WEIGHT);
        assertEq(manager.totalWeight(), BASE_WEIGHT);
        distributor.fund(REWARD_100);
        vm.prank(alice);
        manager.withdraw(TOKEN_ONE);
        assertEq(manager.weightOf(TOKEN_ONE), 0);
        assertEq(manager.totalWeight(), 0);
        vm.prank(alice);
        distributor.claimCredits();
        assertEq(usdg.balanceOf(alice), REWARD_100);
    }

    function testOnlyNFTCanInvokeTransferHook() public {
        vm.prank(alice);
        vm.expectRevert(ActivationManager.NotFlowerNFT.selector);
        manager.onNftTransfer(TOKEN_ONE, alice, bob);
    }

    function testFundingWithoutActiveWeightReverts() public {
        vm.expectRevert(RewardDistributor.NoActiveWeight.selector);
        distributor.fund(1 ether);
    }

    function testClaimBatchIsBounded() public {
        uint256[] memory ids = new uint256[](distributor.MAX_CLAIM_BATCH() + 1);
        vm.prank(alice);
        vm.expectRevert(RewardDistributor.ClaimBatchTooLarge.selector);
        distributor.claim(ids);
    }

    function _completeReserveAllocation() internal {
        uint256 remaining = nft.RESERVED_SUPPLY() - nft.reservedMinted();
        while (remaining != 0) {
            uint256 quantity = remaining > 100 ? 100 : remaining;
            nft.reserveMint(alice, quantity);
            remaining -= quantity;
        }
    }
}
