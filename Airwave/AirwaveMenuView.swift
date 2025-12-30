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
        if hasWarning { return "MenuBarIconWarning" }
        return audioManager.isRunning ? "MenuBarIconFilled" : "MenuBarIcon"
    }
    
    var body: some View {
        if iconName == "MenuBarIconWarning" {
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
                .background(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
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
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
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
            .background(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
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
            .background(isHovered ? Color.accentColor.opacity(0.2) : Color.clear)
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
    @ObservedObject private var viewModel = MenuBarViewModel.shared
    @ObservedObject private var diagnosticsManager = SystemDiagnosticsManager.shared
    
    // Accordion state
    enum ExpandedAccordion {
        case none
        case aggregateDevice
        case outputDevice
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
                // Aggregate Device Accordion
                AccordionSection(
                    title: "Aggregate",
                    value: audioManager.aggregateDevice?.name ?? "None",
                    isExpanded: expandedAccordion == .aggregateDevice,
                    onToggle: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            expandedAccordion = expandedAccordion == .aggregateDevice ? .none : .aggregateDevice
                        }
                    }
                ) {
                    let aggregates = viewModel.getValidAggregateDevices()
                    if aggregates.isEmpty {
                        Text("No aggregate devices found")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(aggregates, id: \.id) { device in
                                DeviceRow(
                                    name: device.name,
                                    isSelected: device.id == audioManager.aggregateDevice?.id
                                ) {
                                    viewModel.selectAggregateDevice(device)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                
                // Output Device Accordion
                if audioManager.aggregateDevice != nil {
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
                        if audioManager.availableOutputs.isEmpty {
                            Text("No output devices in aggregate")
                                .foregroundColor(.secondary)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(audioManager.availableOutputs, id: \.uid) { output in
                                    DeviceRow(
                                        name: "\(output.name) (Ch \(output.startChannel)-\(output.endChannel))",
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
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .opacity(0.3)
                        
                        Text("Output Device")
                            .foregroundColor(.secondary)
                        
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
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
                    viewModel.showSettings()
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
    }
}

#Preview {
    AirwaveMenuView()
        .frame(height: 350)
}

