// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract RhythmCaptcha_FHE is SepoliaConfig {
    struct EncryptedChallenge {
        uint256 id;
        euint32 encryptedPattern;      // Encrypted rhythm pattern
        euint32 encryptedTempo;        // Encrypted tempo in BPM
        euint32 encryptedComplexity;   // Encrypted complexity level
        uint256 timestamp;
        bytes32 sessionId;
    }

    struct EncryptedResponse {
        euint32 encryptedTiming;       // Encrypted response timing
        euint32 encryptedAccuracy;     // Encrypted accuracy score
        ebool isValid;
    }

    struct DecryptedResult {
        uint32 accuracyScore;
        bool isHuman;
        bool isRevealed;
    }

    uint256 public challengeCount;
    mapping(uint256 => EncryptedChallenge) public challenges;
    mapping(bytes32 => EncryptedResponse) public responses;
    mapping(uint256 => DecryptedResult) public results;
    
    mapping(uint256 => uint256) private requestToChallengeId;
    mapping(uint256 => bytes32) private requestToSessionId;
    
    event ChallengeGenerated(uint256 indexed id, bytes32 sessionId, uint256 timestamp);
    event ResponseSubmitted(bytes32 indexed sessionId);
    event VerificationRequested(uint256 indexed challengeId);
    event ResultDecrypted(uint256 indexed challengeId);

    function generateChallenge(
        euint32 pattern,
        euint32 tempo,
        euint32 complexity,
        bytes32 sessionId
    ) public {
        challengeCount += 1;
        uint256 newId = challengeCount;
        
        challenges[newId] = EncryptedChallenge({
            id: newId,
            encryptedPattern: pattern,
            encryptedTempo: tempo,
            encryptedComplexity: complexity,
            timestamp: block.timestamp,
            sessionId: sessionId
        });
        
        emit ChallengeGenerated(newId, sessionId, block.timestamp);
    }

    function submitEncryptedResponse(
        bytes32 sessionId,
        euint32 timing,
        euint32 accuracy
    ) public {
        responses[sessionId] = EncryptedResponse({
            encryptedTiming: timing,
            encryptedAccuracy: accuracy,
            isValid: FHE.asEbool(false)
        });
        
        emit ResponseSubmitted(sessionId);
    }

    function verifyChallenge(uint256 challengeId) public {
        EncryptedChallenge storage challenge = challenges[challengeId];
        EncryptedResponse storage response = responses[challenge.sessionId];
        
        bytes32[] memory ciphertexts = new bytes32[](5);
        ciphertexts[0] = FHE.toBytes32(challenge.encryptedPattern);
        ciphertexts[1] = FHE.toBytes32(challenge.encryptedTempo);
        ciphertexts[2] = FHE.toBytes32(challenge.encryptedComplexity);
        ciphertexts[3] = FHE.toBytes32(response.encryptedTiming);
        ciphertexts[4] = FHE.toBytes32(response.encryptedAccuracy);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.processVerification.selector);
        requestToChallengeId[reqId] = challengeId;
        
        emit VerificationRequested(challengeId);
    }

    function processVerification(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        uint256 challengeId = requestToChallengeId[requestId];
        require(challengeId != 0, "Invalid request");
        
        EncryptedChallenge storage challenge = challenges[challengeId];
        EncryptedResponse storage response = responses[challenge.sessionId];
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        (uint32 pattern, uint32 tempo, uint32 complexity, uint32 timing, uint32 accuracy) = 
            abi.decode(cleartexts, (uint32, uint32, uint32, uint32, uint32));
        
        bool isValid = validateResponse(pattern, tempo, complexity, timing, accuracy);
        
        response.isValid = FHE.asEbool(isValid);
        
        results[challengeId] = DecryptedResult({
            accuracyScore: accuracy,
            isHuman: isValid,
            isRevealed: true
        });
        
        emit ResultDecrypted(challengeId);
    }

    function requestSessionResult(bytes32 sessionId) public {
        EncryptedResponse storage response = responses[sessionId];
        require(!FHE.decrypt(response.isValid), "Already verified");
        
        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(response.encryptedAccuracy);
        
        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptSessionResult.selector);
        requestToSessionId[reqId] = sessionId;
    }

    function decryptSessionResult(
        uint256 requestId,
        bytes memory cleartexts,
        bytes memory proof
    ) public {
        bytes32 sessionId = requestToSessionId[requestId];
        require(sessionId != bytes32(0), "Invalid request");
        
        FHE.checkSignatures(requestId, cleartexts, proof);
        
        uint32 accuracy = abi.decode(cleartexts, (uint32));
    }

    function getDecryptedResult(uint256 challengeId) public view returns (
        uint32 accuracy,
        bool isHuman,
        bool isRevealed
    ) {
        DecryptedResult storage r = results[challengeId];
        return (r.accuracyScore, r.isHuman, r.isRevealed);
    }

    function validateResponse(
        uint32 pattern,
        uint32 tempo,
        uint32 complexity,
        uint32 timing,
        uint32 accuracy
    ) private pure returns (bool) {
        uint32 expectedTiming = (60000 / tempo) * pattern;
        uint32 timingThreshold = expectedTiming / 10;
        
        bool timingValid = (timing > expectedTiming - timingThreshold) && 
                          (timing < expectedTiming + timingThreshold);
        
        bool accuracyValid = accuracy > (70 + complexity * 5);
        
        return timingValid && accuracyValid;
    }

    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }
}