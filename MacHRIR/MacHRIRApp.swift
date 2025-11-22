//
//  MacHRIRApp.swift
//  MacHRIR
//
//  Created by gamer on 19/11/25.
//

import SwiftUI

@main
struct MacHRIRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
