//
//  AppDelegate.swift
//  Airwave
//
//  Created by gamer on 22/11/25.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Safety check: Restore system audio if app crashed while on BlackHole
        checkAndRestoreSystemAudio()
        
        // Setup signal handlers to catch Xcode stop/termination
        setupSignalHandlers()
    }
    
    /// Setup signal handlers to catch termination from Xcode or system
    private func setupSignalHandlers() {
        // Handle SIGTERM (graceful termination request)
        signal(SIGTERM) { _ in
            Logger.log("[AppDelegate] Caught SIGTERM - restoring audio before exit")
            AppDelegate.handleTermination()
            exit(0)
        }
        
        // Handle SIGINT (Ctrl+C or Xcode stop)
        signal(SIGINT) { _ in
            Logger.log("[AppDelegate] Caught SIGINT - restoring audio before exit")
            AppDelegate.handleTermination()
            exit(0)
        }
    }
    
    /// Handle termination - restore system audio with volume matching
    private static func handleTermination() {
        let audioManager = AudioGraphManager.shared
        if audioManager.isRunning {
            // Synchronously restore audio (can't use async in signal handler)
            let deviceManager = AudioDeviceManager.shared
            
            // Get current BlackHole volume
            if let currentOutput = deviceManager.getSystemDefaultOutputDevice(),
               let currentVolume = deviceManager.getDeviceVolume(currentOutput),
               let selectedOutput = audioManager.selectedOutputDevice {
                
                // Set volume on physical device
                _ = deviceManager.setDeviceVolume(selectedOutput.device, volume: currentVolume)
                
                // Switch back to physical device
                _ = deviceManager.setSystemDefaultOutputDevice(selectedOutput.device)
                
                Logger.log("[AppDelegate] ✅ Audio restored on signal termination")
            }
        }
    }
    
    /// Check if system audio is on BlackHole but engine is off, and restore if needed
    /// This handles the case where the app crashed while the engine was running
    private func checkAndRestoreSystemAudio() {
        let deviceManager = AudioDeviceManager.shared
        let audioManager = AudioGraphManager.shared
        
        // Get current system default output
        guard let currentOutput = deviceManager.getSystemDefaultOutputDevice() else {
            return
        }
        
        // Check if system is currently on BlackHole
        let isOnBlackHole = VirtualAudioDriver.isBlackHole(deviceName: currentOutput.name)
        
        // Check if audio engine is NOT running
        let engineNotRunning = !audioManager.isRunning
        
        // If on BlackHole but engine is off, restore saved device
        if isOnBlackHole && engineNotRunning {
            Logger.log("[AppDelegate] Detected BlackHole system output with engine off - attempting recovery")
            let restored = deviceManager.restoreSavedOutputDevice()
            
            if restored {
                Logger.log("[AppDelegate] ✅ System audio restored after detected crash")
            } else {
                Logger.log("[AppDelegate] ⚠️ Could not restore system audio - no saved device found")
            }
        }
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // If audio engine is running, stop it (which will restore system audio)
        let audioManager = AudioGraphManager.shared
        if audioManager.isRunning {
            Logger.log("[AppDelegate] App terminating with engine running - stopping gracefully")
            audioManager.stop()
        }
    }
}
