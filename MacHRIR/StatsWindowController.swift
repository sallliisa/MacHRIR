//
//  StatsWindowController.swift
//  MacHRIR
//
//  Buffer utilization stats window for debugging
//

#if DEBUG_STATS_WINDOW

import AppKit
import Combine

/// Window controller for displaying buffer statistics
class StatsWindowController: NSWindowController {
    
    private var audioManager: AudioGraphManager?
    private var updateTimer: Timer?
    private let updateInterval: TimeInterval = 0.1 // 10 Hz
    
    // UI Components - Buffer Stats
    private let capacityLabel = NSTextField(labelWithString: "")
    private let usedLabel = NSTextField(labelWithString: "")
    private let availableLabel = NSTextField(labelWithString: "")
    private let percentLabel = NSTextField(labelWithString: "")
    private let bufferingLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    
    // UI Components - Drift Stats
    private let underrunLabel = NSTextField(labelWithString: "")
    private let avgFillLabel = NSTextField(labelWithString: "")
    private let minFillLabel = NSTextField(labelWithString: "")
    private let maxFillLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Reset Drift Stats", target: nil, action: nil)
    
    init(audioManager: AudioGraphManager) {
        self.audioManager = audioManager
        
        // Create window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Buffer Statistics"
        window.level = .floating
        window.center()
        
        super.init(window: window)
        
        setupUI()
        startUpdating()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        stopUpdating()
    }
    
    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        
        // Create container stack view
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        // Configure labels
        let titleLabel = NSTextField(labelWithString: "Circular Buffer Utilization")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        
        capacityLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        usedLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        availableLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        percentLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        bufferingLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        
        underrunLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        avgFillLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        minFillLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        maxFillLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        
        // Configure reset button
        resetButton.target = self
        resetButton.action = #selector(resetDriftStats)
        resetButton.bezelStyle = .rounded
        
        // Configure progress bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        
        // Add components to stack
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(createSeparator())
        stackView.addArrangedSubview(capacityLabel)
        stackView.addArrangedSubview(usedLabel)
        stackView.addArrangedSubview(availableLabel)
        stackView.addArrangedSubview(createSeparator())
        stackView.addArrangedSubview(percentLabel)
        stackView.addArrangedSubview(progressBar)
        stackView.addArrangedSubview(createSeparator())
        stackView.addArrangedSubview(bufferingLabel)
        
        // Drift monitoring section
        let driftTitleLabel = NSTextField(labelWithString: "Clock Drift Monitoring")
        driftTitleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        stackView.addArrangedSubview(createSeparator())
        stackView.addArrangedSubview(driftTitleLabel)
        stackView.addArrangedSubview(createSeparator())
        stackView.addArrangedSubview(underrunLabel)
        stackView.addArrangedSubview(avgFillLabel)
        stackView.addArrangedSubview(minFillLabel)
        stackView.addArrangedSubview(maxFillLabel)
        stackView.addArrangedSubview(resetButton)
        
        contentView.addSubview(stackView)
        
        // Layout constraints
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            
            progressBar.widthAnchor.constraint(equalTo: stackView.widthAnchor)
        ])
        
        // Initial update
        updateStats()
    }
    
    private func createSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        return separator
    }
    
    private func startUpdating() {
        updateTimer = Timer.scheduledTimer(
            withTimeInterval: updateInterval,
            repeats: true
        ) { [weak self] _ in
            self?.updateStats()
        }
    }
    
    private func stopUpdating() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func updateStats() {
        guard let stats = audioManager?.getBufferStats() else {
            capacityLabel.stringValue = "Capacity: N/A"
            usedLabel.stringValue = "Used: N/A"
            availableLabel.stringValue = "Available: N/A"
            percentLabel.stringValue = "Fill: N/A"
            bufferingLabel.stringValue = "Status: Not Running"
            progressBar.doubleValue = 0
            return
        }
        
        // Format bytes to human-readable
        capacityLabel.stringValue = String(format: "Capacity:  %@", formatBytes(stats.capacity))
        usedLabel.stringValue = String(format: "Used:      %@ (%.1f%%)", 
                                       formatBytes(stats.bytesUsed), 
                                       stats.percentFull)
        availableLabel.stringValue = String(format: "Available: %@ (%.1f%%)", 
                                            formatBytes(stats.bytesAvailable),
                                            100.0 - stats.percentFull)
        
        percentLabel.stringValue = String(format: "Buffer Fill: %.1f%%", stats.percentFull)
        progressBar.doubleValue = stats.percentFull
        
        // Update buffering status with color
        if stats.isBuffering {
            bufferingLabel.stringValue = "⚠️ Status: BUFFERING"
            bufferingLabel.textColor = .systemOrange
        } else {
            bufferingLabel.stringValue = "✓ Status: Normal"
            bufferingLabel.textColor = .systemGreen
        }
        
        // Update drift statistics
        underrunLabel.stringValue = String(format: "Underruns:    %d", stats.underrunCount)
        avgFillLabel.stringValue = String(format: "Avg Fill:     %@ (%.1f%%)",
                                          formatBytes(Int(stats.averageFillLevel)),
                                          (stats.averageFillLevel / Double(stats.capacity)) * 100.0)
        minFillLabel.stringValue = String(format: "Min Fill:     %@ (%.1f%%)",
                                          formatBytes(stats.minFillLevel),
                                          (Double(stats.minFillLevel) / Double(stats.capacity)) * 100.0)
        maxFillLabel.stringValue = String(format: "Max Fill:     %@ (%.1f%%)",
                                          formatBytes(stats.maxFillLevel),
                                          (Double(stats.maxFillLevel) / Double(stats.capacity)) * 100.0)
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    @objc private func resetDriftStats() {
        audioManager?.resetDriftStats()
    }
    
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        startUpdating()
    }
    
    override func close() {
        stopUpdating()
        super.close()
    }
}

#endif
