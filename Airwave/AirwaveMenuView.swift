//
//  AirwaveMenuView.swift
//  Airwave
//
//  SwiftUI MenuBarExtra implementation for macOS 15+
//

import SwiftUI

// MARK: - Menu Bar Label (Status Icon)

struct MenuBarLabel: View {
    @ObservedObject private var audioManager = AudioGraphManager.shared
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    
    private var iconName: String {
        let hasWarning = !diagnosticsManager.diagnostics.isFullyConfigured
        if hasWarning { return "MenuBarIcon.warning" }
        return audioManager.isRunning ? "MenuBarIcon.filled" : "MenuBarIcon"
    }
    
    var body: some View {
        if iconName == "MenuBarIcon.warning" {
            Image(iconName)
                .renderingMode(.original)
        } else {
            Image(iconName)
                .renderingMode(.template)
        }
    }
}

// MARK: - Menu Header Section

struct MenuHeaderSection: View {
    @ObservedObject private var audioManager = AudioGraphManager.shared
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    
    private var canToggle: Bool {
        diagnosticsManager.diagnostics.isFullyConfigured && audioManager.aggregateDevice != nil
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // Icon
            if let icon = NSImage(named: "AirwaveIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            }
            
            // Title
            Text("Airwave")
                .font(.system(size: 13, weight: .semibold))
            
            Spacer()
            
            // Audio Engine Toggle
            Toggle("", isOn: Binding(
                get: { audioManager.isRunning },
                set: { shouldRun in
                    if shouldRun {
                        audioManager.start()
                    } else {
                        audioManager.stop()
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!canToggle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

// MARK: - Menu Row Style

struct MenuRowStyle: ViewModifier {
    @State private var isHovered = false
    
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
            .cornerRadius(12)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

extension View {
    func menuRowStyle() -> some View {
        modifier(MenuRowStyle())
    }
}

// MARK: - Accordion Section

struct AccordionSection<Content: View>: View {
    let title: String
    let value: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    // Disclosure triangle
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                    
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                    
                    Spacer(minLength: 4)
                    
                    if !isExpanded {
                        Text(value)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 140, alignment: .trailing)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .cornerRadius(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // Expandable content
            if isExpanded {
                VStack(spacing: 0) {
                    content()
                }
                .padding(.leading, 10)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Device Row

struct DeviceRow: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 12))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                
                Spacer(minLength: 4)
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 15)
            .padding(.vertical, 5)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Submenu Row

struct SubmenuRow<Content: View>: View {
    let title: String
    let value: String
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false
    @State private var showSubmenu = false
    
    var body: some View {
        Menu {
            content()
        } label: {
            HStack {
                Text(title)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(12)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

// MARK: - Action Row

struct ActionRow: View {
    let title: String
    let shortcut: String?
    let showWarning: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    init(_ title: String, shortcut: String? = nil, showWarning: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.showWarning = showWarning
        self.action = action
    }
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if showWarning {
                    Text("⚠️")
                }
                if let shortcut = shortcut {
                    Text(shortcut)
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .cornerRadius(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Main Menu View

struct AirwaveMenuView: View {
    @ObservedObject private var audioManager = AudioGraphManager.shared
    @ObservedObject private var hrirManager = HRIRManager.shared
    @EnvironmentObject private var viewModel: MenuBarViewModel
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    @Environment(\.openWindow) private var openWindow
    
    // Static UUID for "None" option in HRIR picker
    private static let nonePresetID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    
    // Accordion state
    enum ExpandedAccordion {
        case none
        case outputDevice
        case hrirPreset
    }
    
    @State private var expandedAccordion: ExpandedAccordion = .none
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with toggle
            MenuHeaderSection()
            
            Divider()
                .padding(.horizontal, 10)
            
            // Device selection
            VStack(spacing: 2) {
                // Output Device Section
                if audioManager.aggregateDevice != nil {
                    if audioManager.availableOutputs.isEmpty {
                        // Disabled state when no outputs available
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                                .opacity(0.3)
                            
                            Text("Output Device")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    } else {
                        // Accordion when outputs exist
                        AccordionSection(
                            title: "Output",
                            value: audioManager.selectedOutputDevice?.name ?? "None",
                            isExpanded: expandedAccordion == .outputDevice,
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedAccordion = expandedAccordion == .outputDevice ? .none : .outputDevice
                                }
                            }
                        ) {
                            VStack(spacing: 0) {
                                ForEach(audioManager.availableOutputs, id: \.uid) { output in
                                    DeviceRow(
                                        name: output.name,
                                        isSelected: output.device.id == audioManager.selectedOutputDevice?.device.id
                                    ) {
                                        viewModel.selectOutputDevice(output)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .opacity(0.3)
                        
                        Text("Output Device")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                
                // HRIR Preset Section
                AccordionSection(
                    title: "HRIR Preset",
                    value: hrirManager.activePreset?.name ?? "None",
                    isExpanded: expandedAccordion == .hrirPreset,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedAccordion = expandedAccordion == .hrirPreset ? .none : .hrirPreset
                        }
                    }
                ) {
                    VStack(spacing: 0) {
                        // None option
                        DeviceRow(
                            name: "None",
                            isSelected: hrirManager.activePreset == nil
                        ) {
                            hrirManager.activePreset = nil
                        }
                        
                        // Preset options (sorted alphabetically)
                        ForEach(hrirManager.presets.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { preset in
                            DeviceRow(
                                name: preset.name,
                                isSelected: preset.id == hrirManager.activePreset?.id
                            ) {
                                let sampleRate = 48000.0
                                let channelCount = audioManager.selectedInputDevice?.inputChannelRange?.count ?? 2
                                let inputLayout = InputLayout.detect(channelCount: channelCount)
                                hrirManager.activatePreset(preset, targetSampleRate: sampleRate, inputLayout: inputLayout)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
            
            Divider()
                .padding(.horizontal, 10)
            
            // Settings
            VStack(spacing: 2) {
                ActionRow(
                    "Settings",
                    showWarning: !diagnosticsManager.diagnostics.isFullyConfigured
                ) {
                    viewModel.closeMenuBarPopover()
                    openWindow(id: "settings")
                }
            }
            .padding(.vertical, 4)
            
            Divider()
                .padding(.horizontal, 10)
            
            // About & Quit
            VStack(spacing: 2) {
                ActionRow("About Airwave") {
                    viewModel.showAbout()
                }
                
                ActionRow("Quit Airwave", shortcut: "⌘Q") {
                    viewModel.quitApp()
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 280)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .alert(item: $viewModel.selectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

#Preview {
    AirwaveMenuView()
        .frame(height: 350)
}
