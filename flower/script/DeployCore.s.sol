// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FLOWER} from "../src/FLOWER.sol";
import {FlowerNFT} from "../src/FlowerNFT.sol";
import {ActivationManager} from "../src/ActivationManager.sol";
import {RewardDistributor} from "../src/RewardDistributor.sol";
import {IFLOWER} from "../src/interfaces/IFLOWER.sol";
import {IWeightProvider} from "../src/interfaces/IWeightProvider.sol";

contract DeployCore is Script {
    function run()
        external
        returns (
            FLOWER flower,
            FlowerNFT nft,
            ActivationManager manager,
            RewardDistributor distributor
        )
    {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address ownerSafe = vm.envAddress("OWNER_SAFE");
        address treasurySafe = vm.envAddress("TREASURY_SAFE");
        address quoteToken = vm.envAddress("USDG");
        uint256 mintPriceUnits = vm.envUint("QUOTE_MINT_PRICE_UNITS");
        string memory baseURI = vm.envString("NFT_BASE_URI");

        vm.startBroadcast(pk);
        flower = new FLOWER(vm.addr(pk));
        nft = new FlowerNFT(ownerSafe, IERC20(quoteToken), treasurySafe, mintPriceUnits, baseURI);
        manager = new ActivationManager(ownerSafe, nft, IFLOWER(address(flower)));
        distributor = new RewardDistributor(
            IERC20(quoteToken), nft, IWeightProvider(address(manager)), address(manager)
        );
        vm.stopBroadcast();
    }
}
