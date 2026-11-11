//
//  Commands.swift
//  SatTracker
//

import SwiftUI

struct SatTrackerCommands: Commands {

    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .textEditing) {
            Button("Find Satellite…") { model.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Refresh Elements") { model.refresh(force: true) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isRefreshing)
        }

        CommandMenu("View") {
            Button("Reset Camera") { model.resetCamera() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()

            Toggle("Orbit Path", isOn: Binding(get: { model.showOrbitPath },
                                               set: { model.setShowOrbitPath($0) }))
                .keyboardShortcut("o", modifiers: [.command, .option])
            Toggle("Ground Track", isOn: Binding(get: { model.showGroundTrack },
                                                 set: { model.setShowGroundTrack($0) }))
                .keyboardShortcut("g", modifiers: [.command, .option])
            Toggle("Ground Station", isOn: Binding(get: { model.showObserver },
                                                   set: { model.setShowObserver($0) }))

            Divider()

            Button("Save View as Image…") { model.saveSnapshotWithPanel() }
                .keyboardShortcut("s", modifiers: [.command, .shift])

            Divider()

            Button("Show All Groups") { model.setAllGroups(true) }
            Button("Hide All Groups") { model.setAllGroups(false) }
        }

        CommandMenu("Satellite") {
            Button(model.favoriteActionTitle) { model.toggleFavoriteSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selectedIndex == nil)

            Button("Clear Selection") { model.select(nil) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(model.selectedIndex == nil)
        }
    }
}
