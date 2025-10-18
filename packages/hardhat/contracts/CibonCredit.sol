 // SPDX-License-Identifier: BSD-3-Clause-Clear
 pragma solidity ^0.8.27;
 
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {FHE, externalEuint64, euint64} from "@fhevm/solidity/lib/FHE.sol";
import {SepoliaConfig} from "@fhevm/solidity/config/ZamaConfig.sol";
import {ConfidentialFungibleToken} from "@openzeppelin/confidential-contracts/token/ConfidentialFungibleToken.sol";
 
contract CibonCredit is SepoliaConfig, ConfidentialFungibleToken, Ownable2Step, AccessControl {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event CreditsMinted(address indexed to, uint256 amount);

    /// -----------------------------------------------------------------------
    /// Minter role for carbon credit minting
    /// -----------------------------------------------------------------------
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(
        uint64 amount,
        string memory name_,
        string memory symbol_,
        string memory tokenURI_
    ) ConfidentialFungibleToken(name_, symbol_, tokenURI_) Ownable(msg.sender) {
        euint64 encryptedAmount = FHE.asEuint64(amount);
        _mint(msg.sender, encryptedAmount);
    }

    /// -----------------------------------------------------------------------
    /// Minting functions for carbon credits
    /// -----------------------------------------------------------------------
    
    /// Mint carbon credits to a user (restricted to MINTER_ROLE)
    /// This function mints and transfers encrypted tokens directly to the recipient
    function mintCredits(address to, uint256 amount) external {
        require(hasRole(MINTER_ROLE, msg.sender), "Only minters can mint credits");
        require(amount > 0, "Amount must be greater than 0");
        
        euint64 encryptedAmount = FHE.asEuint64(uint64(amount));
        _mint(to, encryptedAmount); // Mints tokens directly to the recipient's balance
        
        emit CreditsMinted(to, amount);
    }
    
    /// Grant minter role to carbon footprint calculator
    function grantMinterRole(address minter) external onlyOwner {
        _grantRole(MINTER_ROLE, minter);
    }
}