// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    FHE,
    euint32,
    euint64,
    externalEuint32,
    ebool
} from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @dev Minimal mint interface for your carbon credit token (must grant MINTER to this contract)
interface ICarbonCreditToken {
    function mint(address to, uint256 amount) external;
}

/// @title CibonCarbonFootprintCalculator
/// @notice Privacy-preserving carbon footprint calculator using FHEVM.
///         Users submit encrypted activity; contract computes encrypted total CO2e.
///         A designated oracle (off-chain) decrypts and calls oracleMint to drop credit tokens.
contract CibonCarbonFootprintCalculator is SepoliaConfig {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event Submitted(address indexed user);
    event FactorsUpdated(uint32 kwh, uint32 carKm, uint32 transitKm, uint32 flightKm);
    event PolicyUpdated(uint64 baselineGrams, uint64 gramsPerToken);
    event OracleUpdated(address indexed oracle);
    event TokenUpdated(address indexed token);

    /// -----------------------------------------------------------------------
    /// Roles / Addresses
    /// -----------------------------------------------------------------------
    address public oracle;                 // Off-chain service allowed to mint based on clear totals
    ICarbonCreditToken public creditToken; // ERC20 with a mint method callable by this contract

    /// -----------------------------------------------------------------------
    /// Public emission factors (grams CO2e per unit)
    /// Keep these public/clear; the inputs remain encrypted.
    /// -----------------------------------------------------------------------
    struct Factors {
        uint32 gramsPerKwh;       // grams CO2e per kWh electricity
        uint32 gramsPerCarKm;     // grams CO2e per km by car
        uint32 gramsPerTransitKm; // grams CO2e per km public transit
        uint32 gramsPerFlightKm;  // grams CO2e per flight km (simple demo factor)
    }

    Factors public factors;

    /// -----------------------------------------------------------------------
    /// Minting policy
    /// baselineGrams: a period baseline (grams CO2e). If user's total < baseline,
    /// they earn (baseline - total) / gramsPerToken credits.
    /// -----------------------------------------------------------------------
    uint64 public baselineGrams;
    uint64 public gramsPerToken;

    /// -----------------------------------------------------------------------
    /// Per-user encrypted totals
    /// -----------------------------------------------------------------------
    mapping(address => euint64) private _userTotalGrams;

    /// -----------------------------------------------------------------------
    /// Modifiers
    /// -----------------------------------------------------------------------
    modifier onlyOracle() {
        require(msg.sender == oracle, "Not oracle");
        _;
    }

    modifier validToken() {
        require(address(creditToken) != address(0), "Token not set");
        _;
    }

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------
    constructor(
        address oracle_,
        address creditToken_,
        Factors memory initFactors,
        uint64 baselineGrams_,
        uint64 gramsPerToken_
    ) {
        oracle = oracle_;
        creditToken = ICarbonCreditToken(creditToken_);
        factors = initFactors;
        baselineGrams = baselineGrams_;
        gramsPerToken = gramsPerToken_;
        emit FactorsUpdated(initFactors.gramsPerKwh, initFactors.gramsPerCarKm, initFactors.gramsPerTransitKm, initFactors.gramsPerFlightKm);
        emit PolicyUpdated(baselineGrams, gramsPerToken);
        emit OracleUpdated(oracle_);
        emit TokenUpdated(creditToken_);
    }

    /// -----------------------------------------------------------------------
    /// Admin setters (ownerless demo; in production gate these with Ownable)
    /// -----------------------------------------------------------------------
    function setOracle(address oracle_) external {
        oracle = oracle_;
        emit OracleUpdated(oracle_);
    }

    function setCreditToken(address token_) external {
        creditToken = ICarbonCreditToken(token_);
        emit TokenUpdated(token_);
    }

    function setFactors(Factors calldata f) external {
        factors = f;
        emit FactorsUpdated(f.gramsPerKwh, f.gramsPerCarKm, f.gramsPerTransitKm, f.gramsPerFlightKm);
    }

    function setPolicy(uint64 baselineGrams_, uint64 gramsPerToken_) external {
        baselineGrams = baselineGrams_;
        gramsPerToken = gramsPerToken_;
        emit PolicyUpdated(baselineGrams_, gramsPerToken_);
    }

    /// -----------------------------------------------------------------------
    /// Submit encrypted activity
    /// Users pass encrypted values + input proof (FHEVM pattern).
    /// We multiply by public factors and sum to an encrypted total grams CO2e.
    /// We grant view permissions to msg.sender and the oracle.
    /// -----------------------------------------------------------------------
    struct EncryptedActivity {
        externalEuint32 kwh;        // electricity consumption
        externalEuint32 carKm;      // car kilometers
        externalEuint32 transitKm;  // public transit kilometers
        externalEuint32 flightKm;   // flight kilometers
    }

    function submitEncryptedActivity(
        EncryptedActivity calldata enc,
        bytes calldata inputProof
    ) external {
        // Ingest external ciphertexts
        euint32 kwh        = FHE.fromExternal(enc.kwh, inputProof);
        euint32 carKm      = FHE.fromExternal(enc.carKm, inputProof);
        euint32 transitKm  = FHE.fromExternal(enc.transitKm, inputProof);
        euint32 flightKm   = FHE.fromExternal(enc.flightKm, inputProof);

        // Multiply encrypted values by public emission factors (grams per unit)
        // NOTE: FHEVM supports multiplying ciphertext by a public scalar.
        // Convert plain uint64 factors to encrypted euint64 for multiplication.
        euint64 total =
            FHE.add(
                FHE.add(
                    FHE.mul(FHE.asEuint64(kwh), FHE.asEuint64(uint64(factors.gramsPerKwh))),
                    FHE.mul(FHE.asEuint64(carKm), FHE.asEuint64(uint64(factors.gramsPerCarKm)))
                ),
                FHE.add(
                    FHE.mul(FHE.asEuint64(transitKm), FHE.asEuint64(uint64(factors.gramsPerTransitKm))),
                    FHE.mul(FHE.asEuint64(flightKm), FHE.asEuint64(uint64(factors.gramsPerFlightKm)))
                )
            );

        // Accumulate with any prior submissions for the period (optional)
        euint64 prior = _userTotalGrams[msg.sender];
        euint64 updated = FHE.add(prior, total);
        _userTotalGrams[msg.sender] = updated;

        // Grant viewing to: this contract (for possible future logic), the sender, and the oracle.
        FHE.allowThis(updated);
        FHE.allow(updated, msg.sender);
        if (oracle != address(0)) {
            FHE.allow(updated, oracle);
        }

        emit Submitted(msg.sender);
    }

    /// @notice Return the caller's encrypted total (ciphertext-handle type).
    function getMyEncryptedTotal() external view returns (euint64) {
        return _userTotalGrams[msg.sender];
    }

    /// @notice View any user's encrypted total (useful for oracle; visibility is still permissioned by FHEVM).
    function getEncryptedTotalOf(address user) external view returns (euint64) {
        return _userTotalGrams[user];
    }

    /// -----------------------------------------------------------------------
    /// Oracle settlement: mint credits based on clear total
    /// The oracle decrypts the user's encrypted total off-chain and calls this with the clear grams value.
    /// Policy: credits = max(0, (baselineGrams - totalGrams)) / gramsPerToken
    /// -----------------------------------------------------------------------
    function oracleMint(address user, uint64 totalGramsClear)
        external
        onlyOracle
        validToken
    {
        require(gramsPerToken > 0, "Invalid policy");
        uint256 credits = 0;
        if (totalGramsClear < baselineGrams) {
            credits = (uint256(baselineGrams) - uint256(totalGramsClear)) / uint256(gramsPerToken);
        }
        if (credits > 0) {
            creditToken.mint(user, credits);
        }
        // (Optional) reset user's running total after minting for a "periodic" program:
        // delete _userTotalGrams[user];
    }
}
