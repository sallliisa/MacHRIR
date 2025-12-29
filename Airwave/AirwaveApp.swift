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
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
