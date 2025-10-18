// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    FHE,
    euint32,
    euint64,
    externalEuint32
} from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

/// @title CibonCarbonFootprintCalculator (Oracle-free)
/// @notice Users submit encrypted activity; contract computes an encrypted total CO2e
///         and stores it per user. Only the user can decrypt their own total.
contract CibonCarbonFootprintCalculator is SepoliaConfig {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event Submitted(address indexed user, bool accumulated);
    event FactorsUpdated(uint32 kwh, uint32 carKm, uint32 transitKm, uint32 flightKm);
    event Cleared(address indexed user);

    /// -----------------------------------------------------------------------
    /// Public emission factors (grams CO2e per unit)
    /// Keep these public/clear; user inputs & totals remain encrypted.
    /// -----------------------------------------------------------------------
    struct Factors {
        uint32 gramsPerKwh;       // grams CO2e per kWh electricity
        uint32 gramsPerCarKm;     // grams CO2e per km by car
        uint32 gramsPerTransitKm; // grams CO2e per km public transit
        uint32 gramsPerFlightKm;  // grams CO2e per flight km
    }

    Factors public factors;

    /// -----------------------------------------------------------------------
    /// Per-user encrypted totals (running total in grams CO2e)
    /// -----------------------------------------------------------------------
    mapping(address => euint64) private _userTotalGrams;
    
    /// -----------------------------------------------------------------------
    /// Track which users have submitted data
    /// -----------------------------------------------------------------------
    mapping(address => bool) private _userHasData;

    constructor(Factors memory initFactors) {
        factors = initFactors;
        emit FactorsUpdated(
            initFactors.gramsPerKwh,
            initFactors.gramsPerCarKm,
            initFactors.gramsPerTransitKm,
            initFactors.gramsPerFlightKm
        );
    }

    /// Admin update of factors (gate with Ownable in production)
    function setFactors(Factors calldata f) external {
        factors = f;
        emit FactorsUpdated(f.gramsPerKwh, f.gramsPerCarKm, f.gramsPerTransitKm, f.gramsPerFlightKm);
    }

    /// -----------------------------------------------------------------------
    /// Submit encrypted activity (accumulates into caller's encrypted total)
    /// -----------------------------------------------------------------------
    struct EncryptedActivity {
        externalEuint32 kwh;        // electricity consumption
        externalEuint32 carKm;      // car kilometers
        externalEuint32 transitKm;  // public transit kilometers
        externalEuint32 flightKm;   // flight kilometers
    }

    /// @notice Encrypt-aware submission: builds total = sum(activity_i * factor_i) and accumulates it.
    /// @param enc external encrypted fields
    /// @param inputProof FHEVM input proof (per SDK)
    function submitEncryptedActivity(
        EncryptedActivity calldata enc,
        bytes calldata inputProof
    ) external {
        // Ingest external ciphertexts
        euint32 kwh        = FHE.fromExternal(enc.kwh, inputProof);
        euint32 carKm      = FHE.fromExternal(enc.carKm, inputProof);
        euint32 transitKm  = FHE.fromExternal(enc.transitKm, inputProof);
        euint32 flightKm   = FHE.fromExternal(enc.flightKm, inputProof);

        // The contract should already have permission to perform FHE operations on the encrypted inputs

        // Multiply encrypted values by public emission factors and sum
        // NOTE: If your FHE lib prefers FHE.castToEuint64, swap accordingly.
        euint64 totalThisSubmission =
            FHE.add(
                FHE.add(
                    FHE.mul(FHE.asEuint64(kwh),       FHE.asEuint64(uint64(factors.gramsPerKwh))),
                    FHE.mul(FHE.asEuint64(carKm),     FHE.asEuint64(uint64(factors.gramsPerCarKm)))
                ),
                FHE.add(
                    FHE.mul(FHE.asEuint64(transitKm), FHE.asEuint64(uint64(factors.gramsPerTransitKm))),
                    FHE.mul(FHE.asEuint64(flightKm),  FHE.asEuint64(uint64(factors.gramsPerFlightKm)))
                )
            );

        // Accumulate with any prior total (still encrypted)
        euint64 prior = _userTotalGrams[msg.sender];
        
        // If this is the first submission, prior will be zero, so we can just use totalThisSubmission
        // Otherwise, we need to add them together
        euint64 updated;
        if (_userHasData[msg.sender]) {
            updated = FHE.add(prior, totalThisSubmission);
        } else {
            updated = totalThisSubmission;
        }
        
        _userTotalGrams[msg.sender] = updated;
        
        // Mark that this user has submitted data
        _userHasData[msg.sender] = true;

        // Grant viewing to the user and allow this contract to perform future operations
        FHE.allow(updated, msg.sender);
        FHE.allow(updated, address(this));

        emit Submitted(msg.sender, true);
    }

    /// -----------------------------------------------------------------------
    /// Reads
    /// -----------------------------------------------------------------------

    /// @notice Return the caller's encrypted running total (ciphertext handle).
    /// @dev Only the caller (who has view permission) can decrypt off-chain via the FHE SDK.
    function getMyEncryptedTotal() external view returns (euint64) {
        return _userTotalGrams[msg.sender];
    }

    /// @notice (Optional) check if a user has a non-zero ciphertext stored.
    function hasTotal(address user) external view returns (bool) {
        return _userHasData[user];
    }
}
