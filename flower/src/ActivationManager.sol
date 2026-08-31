// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UD60x18, ud} from "@prb/math/src/UD60x18.sol";

import {IActivationTransferHook} from "./interfaces/IActivationTransferHook.sol";
import {IWeightProvider} from "./interfaces/IWeightProvider.sol";
import {IRewardDistributor} from "./interfaces/IRewardDistributor.sol";

interface IFLOWER is IERC20 {
    function burnFrom(address account, uint256 amount) external;
}

/// @title ActivationManager
/// @notice Escrows temporary FLOWER locks and tracks permanent FLOWER burns by NFT.
/// @dev Reward weights use 18-decimal fixed point (1e18 == 1.0 weight).
///
/// IMPORTANT DURATION SEMANTICS IN THIS REFERENCE IMPLEMENTATION:
/// The selected duration is a MINIMUM lock commitment. The position keeps earning
/// its selected multiplier after the minimum period until the activator withdraws
/// or transfers the NFT. This avoids stale global-weight accounting from automatic
/// expiries. If the desired economic rule is "boost automatically ends at expiry",
/// implement epoch-aligned expiries/checkpointing before production deployment.
contract ActivationManager is
    IActivationTransferHook,
    IWeightProvider,
    Ownable2Step,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;

    uint256 public constant ACTIVATION_FLOOR = 50_000_000 ether;
    uint256 public constant BASE_WEIGHT = 0.25e18;
    uint256 public constant HILL_MIDPOINT = 300_000_000 ether;
    uint256 public constant HILL_POWER = 2.25e18;
    uint256 public constant HILL_MAX_BOOST = 2.75e18;
    uint256 public constant TAIL_COEFFICIENT = 0.15e18;
    uint256 public constant TAIL_SCALE = 1_000_000_000 ether;
    uint256 public constant BURN_COEFFICIENT = 0.30e18;
    uint256 public constant BURN_SCALE = 20_000_000 ether;

    IERC721 public immutable nft;
    IFLOWER public immutable flower;

    IRewardDistributor public rewardDistributor;
    uint256 public override totalWeight;
    uint256 public nextDetachedLockId = 1;

    struct Position {
        address activator;
        uint128 locked;
        uint64 unlockAt;
        uint16 durationDays;
        uint256 weight;
    }

    struct DetachedLock {
        address beneficiary;
        uint128 amount;
        uint64 unlockAt;
        bool claimed;
    }

    mapping(uint256 tokenId => Position) public positions;
    mapping(uint256 tokenId => uint256 amount) public permanentBurned;
    mapping(uint256 detachedId => DetachedLock) public detachedLocks;

    error NotNFTOwner();
    error PositionExists();
    error NoPosition();
    error NotActivator();
    error BelowActivationFloor();
    error InvalidDuration();
    error LockStillCommitted();
    error NotFlowerNFT();
    error InvalidAmount();
    error RewardDistributorAlreadySet();
    error ZeroAddress();
    error DetachedLockUnavailable();

    event RewardDistributorSet(address indexed distributor);
    event Activated(
        uint256 indexed tokenId,
        address indexed activator,
        uint256 locked,
        uint16 durationDays,
        uint64 unlockAt,
        uint256 weight
    );
    event LockIncreased(uint256 indexed tokenId, uint256 added, uint256 newLocked, uint256 newWeight);
    event PermanentBurn(
        uint256 indexed tokenId,
        address indexed owner,
        uint256 burned,
        uint256 cumulativeBurn,
        uint256 newWeight
    );
    event PositionWithdrawn(uint256 indexed tokenId, address indexed activator, uint256 amount);
    event PositionDetached(
        uint256 indexed tokenId,
        uint256 indexed detachedId,
        address indexed activator,
        uint256 amount,
        uint64 unlockAt
    );
    event DetachedLockClaimed(uint256 indexed detachedId, address indexed beneficiary, uint256 amount);

    constructor(address initialOwner, IERC721 nft_, IFLOWER flower_) Ownable(initialOwner) {
        if (address(nft_) == address(0) || address(flower_) == address(0)) revert ZeroAddress();
        nft = nft_;
        flower = flower_;
    }

    function setRewardDistributor(IRewardDistributor distributor) external onlyOwner {
        if (address(rewardDistributor) != address(0)) revert RewardDistributorAlreadySet();
        if (address(distributor) == address(0)) revert ZeroAddress();
        rewardDistributor = distributor;
        emit RewardDistributorSet(address(distributor));
    }

    function activate(uint256 tokenId, uint256 lockAmount, uint16 durationDays)
        external
        nonReentrant
    {
        if (nft.ownerOf(tokenId) != msg.sender) revert NotNFTOwner();
        if (positions[tokenId].activator != address(0)) revert PositionExists();
        if (lockAmount < ACTIVATION_FLOOR) revert BelowActivationFloor();

        uint64 unlockAt = uint64(block.timestamp + _durationSeconds(durationDays));
        IERC20(address(flower)).safeTransferFrom(msg.sender, address(this), lockAmount);

        uint256 newWeight = computeWeight(lockAmount, permanentBurned[tokenId], durationDays);

        positions[tokenId] = Position({
            activator: msg.sender,
            locked: uint128(lockAmount),
            unlockAt: unlockAt,
            durationDays: durationDays,
            weight: newWeight
        });

        totalWeight += newWeight;
        _notifyWeightChange(tokenId, msg.sender, 0, newWeight);

        emit Activated(tokenId, msg.sender, lockAmount, durationDays, unlockAt, newWeight);
    }

    function increaseLock(uint256 tokenId, uint256 additionalAmount) external nonReentrant {
        if (additionalAmount == 0) revert InvalidAmount();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotNFTOwner();

        Position storage p = positions[tokenId];
        if (p.activator == address(0)) revert NoPosition();
        if (p.activator != msg.sender) revert NotActivator();

        IERC20(address(flower)).safeTransferFrom(msg.sender, address(this), additionalAmount);

        uint256 oldWeight = p.weight;
        uint256 newLocked = uint256(p.locked) + additionalAmount;
        uint256 newWeight = computeWeight(newLocked, permanentBurned[tokenId], p.durationDays);

        p.locked = uint128(newLocked);
        p.weight = newWeight;

        _replaceTotalWeight(oldWeight, newWeight);
        _notifyWeightChange(tokenId, msg.sender, oldWeight, newWeight);

        emit LockIncreased(tokenId, additionalAmount, newLocked, newWeight);
    }

    function burnForDevelopment(uint256 tokenId, uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotNFTOwner();

        flower.burnFrom(msg.sender, amount);
        permanentBurned[tokenId] += amount;

        Position storage p = positions[tokenId];
        uint256 newWeight = 0;

        if (p.activator != address(0)) {
            uint256 oldWeight = p.weight;
            newWeight = computeWeight(uint256(p.locked), permanentBurned[tokenId], p.durationDays);
            p.weight = newWeight;

            _replaceTotalWeight(oldWeight, newWeight);
            _notifyWeightChange(tokenId, msg.sender, oldWeight, newWeight);
        }

        emit PermanentBurn(tokenId, msg.sender, amount, permanentBurned[tokenId], newWeight);
    }

    function withdraw(uint256 tokenId) external nonReentrant {
        Position memory p = positions[tokenId];
        if (p.activator == address(0)) revert NoPosition();
        if (p.activator != msg.sender) revert NotActivator();
        if (block.timestamp < p.unlockAt) revert LockStillCommitted();

        delete positions[tokenId];
        totalWeight -= p.weight;
        _notifyWeightChange(tokenId, msg.sender, p.weight, 0);

        IERC20(address(flower)).safeTransfer(msg.sender, uint256(p.locked));
        emit PositionWithdrawn(tokenId, msg.sender, uint256(p.locked));
    }

    function onNftTransfer(uint256 tokenId, address from, address)
        external
        override
        nonReentrant
    {
        if (msg.sender != address(nft)) revert NotFlowerNFT();

        Position memory p = positions[tokenId];
        if (p.activator == address(0)) return;
        if (p.activator != from) revert NotActivator();

        delete positions[tokenId];
        totalWeight -= p.weight;
        _notifyWeightChange(tokenId, from, p.weight, 0);

        uint256 detachedId = nextDetachedLockId++;
        detachedLocks[detachedId] = DetachedLock({
            beneficiary: from,
            amount: p.locked,
            unlockAt: p.unlockAt,
            claimed: false
        });

        emit PositionDetached(tokenId, detachedId, from, uint256(p.locked), p.unlockAt);
    }

    function claimDetachedLock(uint256 detachedId) external nonReentrant {
        DetachedLock storage d = detachedLocks[detachedId];
        if (d.beneficiary != msg.sender || d.claimed || d.amount == 0) {
            revert DetachedLockUnavailable();
        }
        if (block.timestamp < d.unlockAt) revert LockStillCommitted();

        d.claimed = true;
        uint256 amount = uint256(d.amount);
        IERC20(address(flower)).safeTransfer(msg.sender, amount);

        emit DetachedLockClaimed(detachedId, msg.sender, amount);
    }

    function weightOf(uint256 tokenId) external view override returns (uint256) {
        return positions[tokenId].weight;
    }

    function computeWeight(uint256 lockAmount, uint256 burnAmount, uint16 durationDays)
        public
        pure
        returns (uint256)
    {
        if (lockAmount < ACTIVATION_FLOOR) return 0;

        UD60x18 total = ud(BASE_WEIGHT);
        uint256 x = lockAmount - ACTIVATION_FLOOR;

        if (x != 0) {
            UD60x18 xFP = ud(x);
            UD60x18 kFP = ud(HILL_MIDPOINT);
            UD60x18 powerFP = ud(HILL_POWER);

            UD60x18 xPow = xFP.pow(powerFP);
            UD60x18 kPow = kFP.pow(powerFP);
            UD60x18 coreFraction = xPow.div(xPow + kPow);
            UD60x18 core = ud(HILL_MAX_BOOST).mul(coreFraction);

            UD60x18 tailRatio = xFP.div(ud(TAIL_SCALE));
            UD60x18 tail = ud(TAIL_COEFFICIENT).mul((ud(WAD) + tailRatio).ln());

            UD60x18 lockComponent = (core + tail).mul(ud(_durationMultiplier(durationDays)));
            total = total + lockComponent;
        } else {
            _durationMultiplier(durationDays);
        }

        if (burnAmount != 0) {
            UD60x18 burnRatio = ud(burnAmount).div(ud(BURN_SCALE));
            UD60x18 burnComponent =
                ud(BURN_COEFFICIENT).mul((ud(WAD) + burnRatio).ln());
            total = total + burnComponent;
        }

        return total.unwrap();
    }

    function _durationMultiplier(uint16 durationDays) internal pure returns (uint256) {
        if (durationDays == 90) return 1.00e18;
        if (durationDays == 180) return 1.10e18;
        if (durationDays == 365) return 1.25e18;
        if (durationDays == 730) return 1.40e18;
        revert InvalidDuration();
    }

    function _durationSeconds(uint16 durationDays) internal pure returns (uint256) {
        _durationMultiplier(durationDays);
        return uint256(durationDays) * 1 days;
    }

    function _replaceTotalWeight(uint256 oldWeight, uint256 newWeight) internal {
        if (newWeight >= oldWeight) {
            totalWeight += newWeight - oldWeight;
        } else {
            totalWeight -= oldWeight - newWeight;
        }
    }

    function _notifyWeightChange(
        uint256 tokenId,
        address beneficiary,
        uint256 oldWeight,
        uint256 newWeight
    ) internal {
        IRewardDistributor distributor = rewardDistributor;
        if (address(distributor) != address(0)) {
            distributor.onWeightChange(tokenId, beneficiary, oldWeight, newWeight);
        }
    }
}
