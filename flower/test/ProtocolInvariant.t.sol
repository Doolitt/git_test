// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {FlowerNFT} from "../src/FlowerNFT.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract InvariantHandler is ERC721Holder {
    uint256 internal constant NFT_COUNT = 5;
    uint256 internal constant MAX_ACTIVATION = 2_000_000_000 ether;
    uint256 internal constant MAX_TOP_UP = 250_000_000 ether;
    uint256 internal constant MAX_BURN = 25_000_000 ether;

    FLOWER public immutable FLOWER_TOKEN;
    FlowerNFT public immutable NFT;
    ActivationManager public immutable MANAGER;

    constructor(FLOWER flower_, FlowerNFT nft_, ActivationManager manager_) {
        FLOWER_TOKEN = flower_;
        NFT = nft_;
        MANAGER = manager_;
        require(flower_.approve(address(manager_), type(uint256).max), "approve failed");
    }

    function activate(uint256 tokenSeed, uint256 amountSeed, uint256 durationSeed) external {
        uint256 tokenId = (tokenSeed % NFT_COUNT) + 1;
        if (NFT.ownerOf(tokenId) != address(this)) return;
        if (MANAGER.weightOf(tokenId) != 0) return;

        uint256 balance = FLOWER_TOKEN.balanceOf(address(this));
        uint256 floor = MANAGER.ACTIVATION_FLOOR();
        if (balance < floor) return;

        uint256 maxAmount = balance < MAX_ACTIVATION ? balance : MAX_ACTIVATION;
        uint256 amount = _range(amountSeed, floor, maxAmount);
        MANAGER.activate(tokenId, amount, _duration(durationSeed));
    }

    function increaseLock(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 tokenId = (tokenSeed % NFT_COUNT) + 1;
        if (MANAGER.weightOf(tokenId) == 0) return;

        uint256 balance = FLOWER_TOKEN.balanceOf(address(this));
        if (balance == 0) return;

        uint256 maxAmount = balance < MAX_TOP_UP ? balance : MAX_TOP_UP;
        uint256 amount = _range(amountSeed, 1, maxAmount);
        MANAGER.increaseLock(tokenId, amount);
    }

    function burnForDevelopment(uint256 tokenSeed, uint256 amountSeed) external {
        uint256 tokenId = (tokenSeed % NFT_COUNT) + 1;
        if (NFT.ownerOf(tokenId) != address(this)) return;

        uint256 balance = FLOWER_TOKEN.balanceOf(address(this));
        if (balance == 0) return;

        uint256 maxAmount = balance < MAX_BURN ? balance : MAX_BURN;
        uint256 amount = _range(amountSeed, 1, maxAmount);
        MANAGER.burnForDevelopment(tokenId, amount);
    }

    function extendDuration(uint256 tokenSeed, uint256 choiceSeed) external {
        uint256 tokenId = (tokenSeed % NFT_COUNT) + 1;
        (address activator,,, uint16 currentDuration,) = MANAGER.positions(tokenId);
        if (activator == address(0)) return;

        uint16 nextDuration;
        if (currentDuration == 90) {
            uint256 choice = choiceSeed % 3;
            nextDuration = choice == 0 ? 180 : choice == 1 ? 365 : 730;
        } else if (currentDuration == 180) {
            nextDuration = choiceSeed % 2 == 0 ? 365 : 730;
        } else if (currentDuration == 365) {
            nextDuration = 730;
        } else {
            return;
        }

        MANAGER.extendDuration(tokenId, nextDuration);
    }

    function _duration(uint256 seed) internal pure returns (uint16) {
        uint256 choice = seed % 4;
        if (choice == 0) return 90;
        if (choice == 1) return 180;
        if (choice == 2) return 365;
        return 730;
    }

    function _range(uint256 seed, uint256 minValue, uint256 maxValue) internal pure returns (uint256) {
        if (maxValue <= minValue) return minValue;
        return minValue + (seed % (maxValue - minValue + 1));
    }
}

contract ProtocolInvariantTest is StdInvariant, Test {
    uint256 internal constant INITIAL_SUPPLY = 1_000_000_000_000 ether;
    uint256 internal constant NFT_COUNT = 5;

    FLOWER internal flower;
    FlowerNFT internal nft;
    ActivationManager internal manager;
    InvariantHandler internal handler;

    function setUp() public {
        MockERC20 quote = new MockERC20("USDG", "USDG");
        flower = new FLOWER(address(this));
        nft = new FlowerNFT(address(this), IERC20(address(quote)), address(0x7777), 250 ether, "ipfs://");
        manager = new ActivationManager(address(this), nft, IFLOWER(address(flower)));
        handler = new InvariantHandler(flower, nft, manager);

        nft.reserveMint(address(handler), NFT_COUNT);
        nft.finalizeReserveMinting();
        assertTrue(flower.transfer(address(handler), 100_000_000_000 ether));

        targetContract(address(handler));
    }

    function invariantTotalWeightEqualsPositionWeights() public view {
        uint256 summedWeight;
        for (uint256 tokenId = 1; tokenId <= NFT_COUNT; ++tokenId) {
            (,,,, uint256 weight) = manager.positions(tokenId);
            summedWeight += weight;
            assertEq(manager.weightOf(tokenId), weight);
        }
        assertEq(manager.totalWeight(), summedWeight);
    }

    function invariantEscrowBalanceEqualsActiveLockedFlower() public view {
        uint256 summedLocked;
        for (uint256 tokenId = 1; tokenId <= NFT_COUNT; ++tokenId) {
            (, uint128 locked,,,) = manager.positions(tokenId);
            summedLocked += uint256(locked);
        }
        assertEq(flower.balanceOf(address(manager)), summedLocked);
    }

    function invariantPermanentBurnAccountingMatchesSupplyReduction() public view {
        uint256 summedBurned;
        for (uint256 tokenId = 1; tokenId <= NFT_COUNT; ++tokenId) {
            summedBurned += manager.permanentBurned(tokenId);
        }
        assertEq(INITIAL_SUPPLY - flower.totalSupply(), summedBurned);
    }

    function invariantActivePositionsMatchEconomicFormula() public view {
        for (uint256 tokenId = 1; tokenId <= NFT_COUNT; ++tokenId) {
            (address activator, uint128 locked,, uint16 durationDays, uint256 weight) = manager.positions(tokenId);
            if (activator == address(0)) {
                assertEq(weight, 0);
                assertEq(locked, 0);
            } else {
                assertEq(activator, address(handler));
                assertGe(uint256(locked), manager.ACTIVATION_FLOOR());
                assertEq(
                    weight,
                    manager.computeWeight(uint256(locked), manager.permanentBurned(tokenId), durationDays)
                );
            }
        }
    }
}
