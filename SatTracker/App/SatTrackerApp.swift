//
//  SatTrackerApp.swift
//  SatTracker
//

import SwiftUI

@main
struct SatTrackerApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 1_060, minHeight: 680)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .defaultSize(width: 1_420, height: 900)
        .commands {
            SatTrackerCommands(model: model)
        }
    }
}
