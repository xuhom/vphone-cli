import AppKit

// MARK: - Features Menu

/// Host sensor controls, with the motion panels grouped in their own submenu.
extension VPhoneMenuController {
    func buildFeaturesMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Features", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Features")
        menu.autoenablesItems = false
        for section in [buildLocationSubmenu(), buildBatterySubmenu(), buildCameraSubmenu()] {
            if menu.numberOfItems > 0 {
                menu.addItem(NSMenuItem.separator())
            }
            menu.addItem(NSMenuItem.sectionHeader(title: section.title))
            // Move, not copy: the controller keeps references to these items.
            let items = section.submenu?.items ?? []
            section.submenu?.removeAllItems()
            for child in items {
                menu.addItem(child)
            }
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(buildMotionSensorsMenu())
        menu.addItem(NSMenuItem.separator())
        let remote = NSMenuItem(title: "LAN Remote", action: nil, keyEquivalent: "")
        let remoteMenu = NSMenu(title: "LAN Remote")
        remoteMenu.autoenablesItems = false
        let toggle = makeItem("Start LAN Remote", action: #selector(toggleLANRemote), symbol: "network")
        remoteToggleItem = toggle
        remoteMenu.addItem(toggle)
        let copy = makeItem("Copy Pairing JSON", action: #selector(copyLANRemotePairing), symbol: "doc.on.doc")
        copy.isEnabled = false
        remoteCopyItem = copy
        remoteMenu.addItem(copy)
        remote.submenu = remoteMenu
        menu.addItem(remote)
        item.submenu = menu
        return item
    }

    @objc func toggleLANRemote() {
        remoteToggleItem?.isEnabled = false
        Task { @MainActor in
            defer { remoteToggleItem?.isEnabled = true }
            do {
                let enabled = try await onRemoteToggle?() ?? false
                setLANRemoteEnabled(enabled)
            } catch {
                VPhoneAlert.present(title: "LAN Remote", message: error.localizedDescription, style: .warning)
            }
        }
    }

    func setLANRemoteEnabled(_ enabled: Bool) {
        remoteToggleItem?.state = enabled ? .on : .off
        remoteToggleItem?.title = enabled ? "Stop LAN Remote" : "Start LAN Remote"
        remoteCopyItem?.isEnabled = enabled
    }

    @objc func copyLANRemotePairing() {
        do {
            guard let pairing = try onRemotePairingCopy?() else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pairing, forType: .string)
        } catch {
            VPhoneAlert.present(title: "LAN Remote", message: error.localizedDescription, style: .warning)
        }
    }
}
