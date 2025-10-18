 // SPDX-License-Identifier: BSD-3-Clause-Clear
 pragma solidity ^0.8.27;
 
 import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
 import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
 import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
 import {ConfidentialFungibleToken} from "@openzeppelin/confidential-contracts/token/ConfidentialFungibleToken.sol";
 
 contract ConfidentialTokenExample is SepoliaConfig, ConfidentialFungibleToken, Ownable2Step {
     constructor(
         uint64 amount,
         string memory name_,
         string memory symbol_,
         string memory tokenURI_
     ) ConfidentialFungibleToken(name_, symbol_, tokenURI_) Ownable(msg.sender) {
         euint64 encryptedAmount = FHE.asEuint64(amount);
         _mint(msg.sender, encryptedAmount);
     }
 }