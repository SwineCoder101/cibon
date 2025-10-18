// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {
    FHE,
    euint32,
    euint64,
    externalEuint32
} from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { CibonCredit } from "./CibonCredit.sol";

/// @title CibonCarbonFootprintCalculator (Oracle-free)
/// @notice Users submit encrypted activity; contract computes an encrypted total CO2e
///         and stores it per user. Only the user can decrypt their own total.
contract CibonCarbonFootprintCalculator is SepoliaConfig, AccessControl {
    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------
    event Submitted(address indexed user, bool accumulated);
    event FactorsUpdated(uint32 kwh, uint32 carKm, uint32 transitKm, uint32 flightKm);
    event Cleared(address indexed user);
    event AssessmentRequested(address indexed user, uint64 totalGrams);
    event CreditsMinted(address indexed user, uint256 credits, uint64 carbonFootprint);
    event CreditParametersUpdated(uint256 baseRate, uint256 scaleFactor, uint256 weightingFactor);

    /// -----------------------------------------------------------------------
    /// Public emission factors (grams CO2e per unit with decimal precision)
    /// Keep these public/clear; user inputs & totals remain encrypted.
    /// Uses scaler factor of 1000 for decimal precision (e.g., 0.4 = 400)
    /// -----------------------------------------------------------------------
    struct Factors {
        uint32 gramsPerKwh;       // grams CO2e per kWh electricity (scaled by 1000)
        uint32 gramsPerCarKm;     // grams CO2e per km by car (scaled by 1000)
        uint32 gramsPerTransitKm; // grams CO2e per km public transit (scaled by 1000)
        uint32 gramsPerFlightKm;  // grams CO2e per flight km (scaled by 1000)
    }

    Factors public factors;
    
    /// -----------------------------------------------------------------------
    /// Scaler factor for decimal precision (1000 = 3 decimal places)
    /// -----------------------------------------------------------------------
    uint32 public constant SCALER_FACTOR = 1000;

    /// -----------------------------------------------------------------------
    /// Admin role for managing emission factors
    /// -----------------------------------------------------------------------
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// -----------------------------------------------------------------------
    /// Credit minting parameters (configurable by admin)
    /// -----------------------------------------------------------------------
    struct CreditParameters {
        uint256 baseRate;        // Base credits per kg CO2e (scaled by 1000)
        uint256 scaleFactor;     // Scaling factor for credit calculation
        uint256 weightingFactor; // Weighting for different activity types
        bool mintingEnabled;     // Whether credit minting is enabled
    }

    CreditParameters public creditParams;

    /// -----------------------------------------------------------------------
    /// Assessment tracking
    /// -----------------------------------------------------------------------
    struct Assessment {
        address user;
        uint64 carbonFootprint; // in grams CO2e
        uint256 creditsEarned;
        bool approved;
        bool processed;
        uint256 timestamp;
    }

    mapping(address => Assessment) public assessments;
    address[] public pendingAssessments;

    /// -----------------------------------------------------------------------
    /// CibonCredit reference for minting credits
    /// -----------------------------------------------------------------------
    CibonCredit public immutable cibonCredit;

    /// -----------------------------------------------------------------------
    /// Per-user encrypted totals (running total in grams CO2e)
    /// -----------------------------------------------------------------------
    mapping(address => euint64) private _userTotalGrams;
    
    /// -----------------------------------------------------------------------
    /// Track which users have submitted data
    /// -----------------------------------------------------------------------
    mapping(address => bool) private _userHasData;

    constructor(Factors memory initFactors, address admin, address creditAddress) {
        factors = initFactors;
        cibonCredit = CibonCredit(creditAddress);
        
        // Set up admin role
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        
        // Initialize credit parameters with default values
        creditParams = CreditParameters({
            baseRate: 100,        // 0.1 credits per kg CO2e (100 with scaler)
            scaleFactor: 1000,    // 1.0 scaling factor (1000 with scaler)
            weightingFactor: 800, // 0.8 weighting factor (800 with scaler)
            mintingEnabled: true
        });
        
        emit FactorsUpdated(
            initFactors.gramsPerKwh,
            initFactors.gramsPerCarKm,
            initFactors.gramsPerTransitKm,
            initFactors.gramsPerFlightKm
        );
        
        emit CreditParametersUpdated(
            creditParams.baseRate,
            creditParams.scaleFactor,
            creditParams.weightingFactor
        );
    }

    /// Admin update of factors (restricted to ADMIN_ROLE)
    function setFactors(Factors calldata f) external onlyRole(ADMIN_ROLE) {
        factors = f;
        emit FactorsUpdated(f.gramsPerKwh, f.gramsPerCarKm, f.gramsPerTransitKm, f.gramsPerFlightKm);
    }

    /// Admin update of factors with decimal precision (restricted to ADMIN_ROLE)
    /// @param kwhPerGrams Decimal factor for kWh (e.g., 0.4 = 400 with scaler)
    /// @param carPerGrams Decimal factor for car km (e.g., 0.12 = 120 with scaler)
    /// @param transitPerGrams Decimal factor for transit km (e.g., 0.05 = 50 with scaler)
    /// @param flightPerGrams Decimal factor for flight km (e.g., 0.285 = 285 with scaler)
    function setFactorsDecimal(
        uint32 kwhPerGrams,
        uint32 carPerGrams,
        uint32 transitPerGrams,
        uint32 flightPerGrams
    ) external onlyRole(ADMIN_ROLE) {
        factors = Factors({
            gramsPerKwh: kwhPerGrams,
            gramsPerCarKm: carPerGrams,
            gramsPerTransitKm: transitPerGrams,
            gramsPerFlightKm: flightPerGrams
        });
        emit FactorsUpdated(kwhPerGrams, carPerGrams, transitPerGrams, flightPerGrams);
    }

    /// -----------------------------------------------------------------------
    /// Credit calculation and assessment functions
    /// -----------------------------------------------------------------------
    
    /// Calculate credits based on carbon footprint using configurable formula
    /// Formula: credits = (carbonFootprint / 1000) * baseRate * scaleFactor * weightingFactor / 1000000
    function calculateCredits(uint64 carbonFootprint) public view returns (uint256) {
        if (!creditParams.mintingEnabled) {
            return 0;
        }
        
        // Convert grams to kg (divide by 1000)
        uint256 carbonKg = uint256(carbonFootprint) / 1000;
        
        // Apply credit formula with scaling
        uint256 credits = (carbonKg * creditParams.baseRate * creditParams.scaleFactor * creditParams.weightingFactor) / 1000000;
        
        return credits;
    }
    
    /// Request assessment for credit minting (triggers auditor notification)
    function requestAssessment() external {
        require(_userHasData[msg.sender], "No carbon footprint data submitted");
        require(!assessments[msg.sender].processed, "Assessment already processed");
        
        // Note: In a real implementation, this would decrypt the user's total
        // For now, we'll emit an event that auditors can listen to
        emit AssessmentRequested(msg.sender, 0); // Placeholder - would need decryption
        
        // Add to pending assessments
        if (!assessments[msg.sender].processed) {
            pendingAssessments.push(msg.sender);
        }
    }
    
    /// Admin function to approve assessment and mint credits
    function approveAssessment(address user, uint64 carbonFootprint) external onlyRole(ADMIN_ROLE) {
        require(_userHasData[user], "No carbon footprint data for user");
        require(!assessments[user].processed, "Assessment already processed");
        
        uint256 credits = calculateCredits(carbonFootprint);
        
        // Mint CibonCredit tokens directly to the user who calculated their carbon footprint
        if (credits > 0) {
            cibonCredit.mintCredits(user, credits);
        }
        
        assessments[user] = Assessment({
            user: user,
            carbonFootprint: carbonFootprint,
            creditsEarned: credits,
            approved: true,
            processed: true,
            timestamp: block.timestamp
        });
        
        // Remove from pending assessments
        for (uint i = 0; i < pendingAssessments.length; i++) {
            if (pendingAssessments[i] == user) {
                pendingAssessments[i] = pendingAssessments[pendingAssessments.length - 1];
                pendingAssessments.pop();
                break;
            }
        }
        
        emit CreditsMinted(user, credits, carbonFootprint);
    }
    
    /// Admin function to reject assessment
    function rejectAssessment(address user) external onlyRole(ADMIN_ROLE) {
        require(!assessments[user].processed, "Assessment already processed");
        
        assessments[user] = Assessment({
            user: user,
            carbonFootprint: 0,
            creditsEarned: 0,
            approved: false,
            processed: true,
            timestamp: block.timestamp
        });
        
        // Remove from pending assessments
        for (uint i = 0; i < pendingAssessments.length; i++) {
            if (pendingAssessments[i] == user) {
                pendingAssessments[i] = pendingAssessments[pendingAssessments.length - 1];
                pendingAssessments.pop();
                break;
            }
        }
    }
    
    /// Admin function to update credit parameters
    function updateCreditParameters(
        uint256 baseRate,
        uint256 scaleFactor,
        uint256 weightingFactor,
        bool mintingEnabled
    ) external onlyRole(ADMIN_ROLE) {
        creditParams = CreditParameters({
            baseRate: baseRate,
            scaleFactor: scaleFactor,
            weightingFactor: weightingFactor,
            mintingEnabled: mintingEnabled
        });
        
        emit CreditParametersUpdated(baseRate, scaleFactor, weightingFactor);
    }
    
    /// Get pending assessments (for auditor dashboard)
    function getPendingAssessments() external view returns (address[] memory) {
        return pendingAssessments;
    }
    
    /// Get user's assessment status
    function getUserAssessment(address user) external view returns (Assessment memory) {
        return assessments[user];
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
        // Apply scaler factor to get correct decimal precision
        euint64 totalThisSubmission =
            FHE.add(
                FHE.add(
                    FHE.div(FHE.mul(FHE.asEuint64(kwh),       FHE.asEuint64(uint64(factors.gramsPerKwh))),       SCALER_FACTOR),
                    FHE.div(FHE.mul(FHE.asEuint64(carKm),     FHE.asEuint64(uint64(factors.gramsPerCarKm))),     SCALER_FACTOR)
                ),
                FHE.add(
                    FHE.div(FHE.mul(FHE.asEuint64(transitKm), FHE.asEuint64(uint64(factors.gramsPerTransitKm))), SCALER_FACTOR),
                    FHE.div(FHE.mul(FHE.asEuint64(flightKm),  FHE.asEuint64(uint64(factors.gramsPerFlightKm))),  SCALER_FACTOR)
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
