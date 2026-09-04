//
//  DomtaApp.swift
//  Domta
//
//  Created by Ratchapol Vanavichit on 25/3/26.
//

import SwiftUI

@main
struct DomtaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
