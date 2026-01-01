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
    
    // Ensure the singleton initializes early and is injected into the view tree.
    @StateObject private var viewModel = MenuBarViewModel.shared
    
    var body: some Scene {
        MenuBarExtra {
            AirwaveMenuView()
                .environmentObject(viewModel)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: "settings") {
            SettingsView()
                .toolbar(removing: .title)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 500, height: 560)
    }
}
