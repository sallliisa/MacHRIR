//
//  AirwaveApp.swift
//  Airwave
//
//  Created by gamer on 19/11/25.
//

import SwiftUI

@main
struct AirwaveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    // Initialize view model to trigger settings loading and device monitoring
    @StateObject private var viewModel = MenuBarViewModel.shared
    
    var body: some Scene {
        MenuBarExtra {
            AirwaveMenuView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
        
        Settings {
            EmptyView()
        }
    }
}
