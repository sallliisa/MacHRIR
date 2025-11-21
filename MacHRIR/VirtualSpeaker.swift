//
//  VirtualSpeaker.swift
//  MacHRIR
//
//  Defines virtual speaker positions and HRIR channel mapping
//

import Foundation

/// Represents a virtual speaker position in 3D space
enum VirtualSpeaker: Hashable, Codable {
    // Standard 7.1 Layout
    case FL  // Front Left
    case FR  // Front Right
    case FC  // Front Center
    case LFE // Low Frequency Effects
    case BL  // Back Left
    case BR  // Back Right
    case SL  // Side Left
    case SR  // Side Right
    
    // Height/Atmos Channels (7.1.4)
    case TFL // Top Front Left
    case TFR // Top Front Right
    case TBL // Top Back Left
    case TBR // Top Back Right
    
    // Additional positions
    case FLC // Front Left Center
    case FRC // Front Right Center
    case BC  // Back Center
    
    // Custom speaker (for arbitrary layouts)
    case custom(String)
    
    var displayName: String {
        switch self {
        case .FL: return "Front Left"
        case .FR: return "Front Right"
        case .FC: return "Front Center"
        case .LFE: return "LFE"
        case .BL: return "Back Left"
        case .BR: return "Back Right"
        case .SL: return "Side Left"
        case .SR: return "Side Right"
        case .TFL: return "Top Front Left"
        case .TFR: return "Top Front Right"
        case .TBL: return "Top Back Left"
        case .TBR: return "Top Back Right"
        case .FLC: return "Front Left Center"
        case .FRC: return "Front Right Center"
        case .BC: return "Back Center"
        case .custom(let name): return name
        }
    }
}

/// Defines the layout of input channels
struct InputLayout {
    let channels: [VirtualSpeaker]
    let name: String
    
    /// Standard stereo layout
    static let stereo = InputLayout(
        channels: [.FL, .FR],
        name: "Stereo"
    )
    
    /// Standard 5.1 surround layout
    static let surround51 = InputLayout(
        channels: [.FL, .FR, .FC, .LFE, .BL, .BR],
        name: "5.1 Surround"
    )
    
    /// Standard 7.1 surround layout
    static let surround71 = InputLayout(
        channels: [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR],
        name: "7.1 Surround"
    )
    
    /// 7.1.4 Atmos layout
    static let atmos714 = InputLayout(
        channels: [.FL, .FR, .FC, .LFE, .BL, .BR, .SL, .SR, .TFL, .TFR, .TBL, .TBR],
        name: "7.1.4 Atmos"
    )
    
    /// Detect layout from channel count
    static func detect(channelCount: Int) -> InputLayout {
        switch channelCount {
        case 2: return .stereo
        case 6: return .surround51
        case 8: return .surround71
        case 12: return .atmos714
        default:
            // Create a generic layout with custom speakers
            let channels = (0..<channelCount).map { VirtualSpeaker.custom("Ch\($0)") }
            return InputLayout(channels: channels, name: "\(channelCount) Channel")
        }
    }
}

/// Maps virtual speakers to HRIR channel indices
struct HRIRChannelMap {
    // Key: Virtual Speaker
    // Value: (Left Ear HRIR Index, Right Ear HRIR Index)
    private var mapping: [VirtualSpeaker: (leftEar: Int, rightEar: Int)] = [:]
    
    /// Add a mapping for a virtual speaker
    mutating func setMapping(speaker: VirtualSpeaker, leftEarIndex: Int, rightEarIndex: Int) {
        mapping[speaker] = (leftEarIndex, rightEarIndex)
    }
    
    /// Get HRIR indices for a virtual speaker
    func getIndices(for speaker: VirtualSpeaker) -> (leftEar: Int, rightEar: Int)? {
        return mapping[speaker]
    }
    
    /// Check if a speaker has a mapping
    func hasMappingFor(_ speaker: VirtualSpeaker) -> Bool {
        return mapping[speaker] != nil
    }
    
    /// Create a standard interleaved pair mapping
    /// Format: Ch0=FL_L, Ch1=FL_R, Ch2=FR_L, Ch3=FR_R, etc.
    /// NOTE: Some HRIR files have the ear channels swapped!
    static func interleavedPairs(speakers: [VirtualSpeaker]) -> HRIRChannelMap {
        var map = HRIRChannelMap()
        for (index, speaker) in speakers.enumerated() {
            // IMPORTANT: Based on RMS analysis, this HRIR file has:
            // Even channels = Direct path (high energy)
            // Odd channels = Cross path (low energy)
            //
            // For Left speaker: Ch0 = L→L (direct), Ch1 = L→R (cross)
            // For Right speaker: Ch2 = R→R (direct!), Ch3 = R→L (cross!)
            //
            // This means the channels are: [Direct, Cross] not [Left, Right]
            // So we need to determine which ear based on speaker position

            let baseIndex = index * 2

            // For left-side speakers (FL, BL, SL, etc.)
            if speaker == .FL || speaker == .BL || speaker == .SL || speaker == .TFL || speaker == .TBL || speaker == .FLC {
                // Ch[base] = Left ear (direct), Ch[base+1] = Right ear (cross)
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex, rightEarIndex: baseIndex + 1)
            }
            // For right-side speakers (FR, BR, SR, etc.)
            else if speaker == .FR || speaker == .BR || speaker == .SR || speaker == .TFR || speaker == .TBR || speaker == .FRC {
                // Ch[base] = Right ear (direct), Ch[base+1] = Left ear (cross)
                // So we SWAP them!
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex + 1, rightEarIndex: baseIndex)
            }
            // For center speakers (FC, BC, LFE)
            else {
                // Center speakers: assume symmetric (both ears get similar response)
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex, rightEarIndex: baseIndex + 1)
            }
        }
        return map
    }

    /// Create the LEGACY swapped mapping (for testing)
    /// This is the old implementation that swaps right channels
    static func interleavedPairsLegacy(speakers: [VirtualSpeaker]) -> HRIRChannelMap {
        var map = HRIRChannelMap()
        for (index, speaker) in speakers.enumerated() {
            // LEGACY: Based on assumption that format is [Direct, Cross]
            // Even channels = Direct path (high energy)
            // Odd channels = Cross path (low energy)
            //
            // For Left speaker: Ch0 = L→L (direct), Ch1 = L→R (cross)
            // For Right speaker: Ch2 = R→R (direct!), Ch3 = R→L (cross!)
            //
            // This means the channels are: [Direct, Cross] not [Left, Right]
            // So we need to determine which ear based on speaker position

            let baseIndex = index * 2

            // For left-side speakers (FL, BL, SL, etc.)
            if speaker == .FL || speaker == .BL || speaker == .SL || speaker == .TFL || speaker == .TBL || speaker == .FLC {
                // Ch[base] = Left ear (direct), Ch[base+1] = Right ear (cross)
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex, rightEarIndex: baseIndex + 1)
            }
            // For right-side speakers (FR, BR, SR, etc.)
            else if speaker == .FR || speaker == .BR || speaker == .SR || speaker == .TFR || speaker == .TBR || speaker == .FRC {
                // Ch[base] = Right ear (direct), Ch[base+1] = Left ear (cross)
                // So we SWAP them!
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex + 1, rightEarIndex: baseIndex)
            }
            // For center speakers (FC, BC, LFE)
            else {
                // Center speakers: assume symmetric (both ears get similar response)
                map.setMapping(speaker: speaker, leftEarIndex: baseIndex, rightEarIndex: baseIndex + 1)
            }
        }
        return map
    }
    
    /// Create a split block mapping
    /// Format: Ch0-N = Left Ear IRs, Ch(N+1)-(2N+1) = Right Ear IRs
    static func splitBlocks(speakers: [VirtualSpeaker]) -> HRIRChannelMap {
        var map = HRIRChannelMap()
        let speakerCount = speakers.count
        for (index, speaker) in speakers.enumerated() {
            let leftEarIndex = index
            let rightEarIndex = index + speakerCount
            map.setMapping(speaker: speaker, leftEarIndex: leftEarIndex, rightEarIndex: rightEarIndex)
        }
        return map
    }

    /// Create HeSuVi 7-channel mapping (Synthesis)
    /// Assumes input channels are: FL, FR, C, BL, BR, SL, SR (Left Ear Only)
    /// We synthesize Right Ear by swapping symmetric channels.
    ///
    /// Mapping Logic:
    /// FL: Left=0 (FL), Right=1 (FR)
    /// FR: Left=1 (FR), Right=0 (FL)
    /// C:  Left=2 (C),  Right=2 (C)
    /// LFE: Left=2 (C), Right=2 (C)
    /// BL: Left=3 (BL), Right=4 (BR)
    /// BR: Left=4 (BR), Right=3 (BL)
    /// SL: Left=5 (SL), Right=6 (SR)
    /// SR: Left=6 (SR), Right=5 (SL)
    static func hesuvi7Channel(speakers: [VirtualSpeaker]) -> HRIRChannelMap {
        var map = HRIRChannelMap()
        
        for speaker in speakers {
            switch speaker {
            case .FL:
                map.setMapping(speaker: speaker, leftEarIndex: 0, rightEarIndex: 1)
            case .FR:
                map.setMapping(speaker: speaker, leftEarIndex: 1, rightEarIndex: 0)
            case .FC:
                map.setMapping(speaker: speaker, leftEarIndex: 2, rightEarIndex: 2)
            case .LFE:
                map.setMapping(speaker: speaker, leftEarIndex: 2, rightEarIndex: 2)
            case .BL:
                map.setMapping(speaker: speaker, leftEarIndex: 3, rightEarIndex: 4)
            case .BR:
                map.setMapping(speaker: speaker, leftEarIndex: 4, rightEarIndex: 3)
            case .SL:
                map.setMapping(speaker: speaker, leftEarIndex: 5, rightEarIndex: 6)
            case .SR:
                map.setMapping(speaker: speaker, leftEarIndex: 6, rightEarIndex: 5)
            default:
                break
            }
        }
        return map
    }

    /// Create HeSuVi 14-channel mapping
    /// Reference:
    /// L0, L1, SL0, SL1, RL0, RL1, C0, R1, R0, SR1, SR0, RR1, RR0, C1
    /// Indices:
    /// 0: L0 (FL Left)
    /// 1: L1 (FL Right)
    /// 2: SL0 (SL Left)
    /// 3: SL1 (SL Right)
    /// 4: RL0 (BL Left)
    /// 5: RL1 (BL Right)
    /// 6: C0 (FC Left)
    /// 7: R1 (FR Right)
    /// 8: R0 (FR Left)
    /// 9: SR1 (SR Right)
    /// 10: SR0 (SR Left)
    /// 11: RR1 (BR Right)
    /// 12: RR0 (BR Left)
    /// 13: C1 (FC Right)
    static func hesuvi14Channel(speakers: [VirtualSpeaker]) -> HRIRChannelMap {
        var map = HRIRChannelMap()
        
        for speaker in speakers {
            switch speaker {
            case .FL:
                map.setMapping(speaker: speaker, leftEarIndex: 0, rightEarIndex: 1)
            case .FR:
                map.setMapping(speaker: speaker, leftEarIndex: 8, rightEarIndex: 7)
            case .FC:
                map.setMapping(speaker: speaker, leftEarIndex: 6, rightEarIndex: 13)
            case .LFE:
                // Map LFE to Center channels
                map.setMapping(speaker: speaker, leftEarIndex: 6, rightEarIndex: 13)
            case .BL: // RL
                map.setMapping(speaker: speaker, leftEarIndex: 4, rightEarIndex: 5)
            case .BR: // RR
                map.setMapping(speaker: speaker, leftEarIndex: 12, rightEarIndex: 11)
            case .SL:
                map.setMapping(speaker: speaker, leftEarIndex: 2, rightEarIndex: 3)
            case .SR:
                map.setMapping(speaker: speaker, leftEarIndex: 10, rightEarIndex: 9)
            default:
                break
            }
        }
        return map
    }
    
    /// Parse a HeSuVi-style mix.txt format
    /// Example: "FL = 0, 1" means FL uses HRIR channels 0 (left) and 1 (right)
    static func parseHeSuViFormat(_ text: String) throws -> HRIRChannelMap {
        var map = HRIRChannelMap()
        
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
                continue
            }
            
            // Parse format: "SPEAKER = LEFT_IDX, RIGHT_IDX"
            let parts = trimmed.components(separatedBy: "=")
            guard parts.count == 2 else { continue }
            
            let speakerName = parts[0].trimmingCharacters(in: .whitespaces)
            let indices = parts[1].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            
            guard indices.count == 2 else { continue }
            
            // Map speaker name to VirtualSpeaker enum
            let speaker: VirtualSpeaker
            switch speakerName.uppercased() {
            case "FL", "L": speaker = .FL
            case "FR", "R": speaker = .FR
            case "FC", "C": speaker = .FC
            case "LFE", "SUB": speaker = .LFE
            case "BL", "RL": speaker = .BL
            case "BR", "RR": speaker = .BR
            case "SL": speaker = .SL
            case "SR": speaker = .SR
            case "TFL": speaker = .TFL
            case "TFR": speaker = .TFR
            case "TBL": speaker = .TBL
            case "TBR": speaker = .TBR
            default: speaker = .custom(speakerName)
            }
            
            map.setMapping(speaker: speaker, leftEarIndex: indices[0], rightEarIndex: indices[1])
        }
        
        return map
    }
}

/// Errors related to HRIR mapping
enum HRIRMappingError: LocalizedError {
    case invalidFormat(String)
    case channelCountMismatch(expected: Int, actual: Int)
    case missingMapping(VirtualSpeaker)
    
    var errorDescription: String? {
        switch self {
        case .invalidFormat(let detail):
            return "Invalid HRIR mapping format: \(detail)"
        case .channelCountMismatch(let expected, let actual):
            return "Channel count mismatch: expected \(expected), got \(actual)"
        case .missingMapping(let speaker):
            return "No HRIR mapping found for speaker: \(speaker.displayName)"
        }
    }
}
