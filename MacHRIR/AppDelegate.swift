//
//  AppDelegate.swift
//  MacHRIR
//
//  Created by gamer on 22/11/25.
//

import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarManager: MenuBarManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize the menu bar manager
        menuBarManager = MenuBarManager()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Perform any cleanup if needed
    }
}
