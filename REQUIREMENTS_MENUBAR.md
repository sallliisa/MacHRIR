# MacHRIR Menu Bar UI Requirements

## Overview

Transform MacHRIR from a traditional window-based application to a menu bar-only application that lives in the macOS menu bar (status bar). This provides a more streamlined, always-accessible interface without cluttering the dock or requiring a dedicated window.

## Core Requirements

### 1. Menu Bar Presence

- **Status Item**: Display a menu bar icon in the macOS status bar (top-right area)
- **Icon Design**: Use a simple, recognizable icon that clearly represents the app's audio/HRIR functionality
- **Icon States**:
  - Inactive state (convolution disabled)
  - Active state (convolution enabled)
  - Optional: Visual indicator when audio is processing

### 2. Menu Structure

When clicking the menu bar icon, display a dropdown menu with the following options:

#### Audio Device Selection

- **Input Device**: Submenu listing all available audio input devices

  - Show currently selected device with a checkmark (✓)
  - Allow selection of any detected input device
  - Display device names clearly

- **Output Device**: Submenu listing all available audio output devices
  - Show currently selected device with a checkmark (✓)
  - Allow selection of any detected output device
  - Display device names clearly

#### HRIR Configuration

- **HRIR Preset**: Submenu listing all available HRIR presets

  - Show currently selected preset with a checkmark (✓)
  - List all `.wav` files from the HRIR presets directory
  - Allow quick switching between presets

- **Open HRIR Directory**: Menu item that opens the HRIR presets folder in Finder
  - Allows users to add/remove HRIR files
  - App should auto-detect changes to this directory

#### Convolution Control

- **Enable/Disable Convolution**: Toggle menu item
  - Show "Enable Convolution" when disabled
  - Show "Disable Convolution" when enabled
  - Include checkmark (✓) or "On/Off" indicator for current state
  - This is the primary control for starting/stopping audio processing

#### Application Management

- **Settings/Preferences**: Optional submenu for additional configuration

  - Auto-start on login
  - Other app preferences as needed

- **About MacHRIR**: Display app version and information

- **Quit MacHRIR**: Cleanly shut down the application
  - Stop audio processing
  - Save current settings
  - Remove menu bar icon

### 3. Window Behavior

- **No Main Window**: The application should NOT display a traditional window in the dock
- **LSUIElement**: Set `LSUIElement` to `true` in `Info.plist` to hide from dock
- **Menu Bar Only**: All interactions happen through the menu bar dropdown
- **No Window Minimize/Maximize**: Since there's no window, these concepts don't apply

### 4. State Persistence

- **Remember Settings**: Persist all user selections across app restarts

  - Last selected input device
  - Last selected output device
  - Last selected HRIR preset
  - Convolution enabled/disabled state

- **Auto-Start**: If convolution was enabled when the app was quit, optionally auto-start on next launch

### 5. User Feedback

- **Visual Indicators**:

  - Menu bar icon should reflect current state (active/inactive)
  - Checkmarks (✓) next to currently selected options in menus
  - Clear labeling of all menu items

- **Notifications**: Optional macOS notifications for:
  - Audio device connection/disconnection
  - HRIR preset changes
  - Errors or warnings

### 6. Performance Considerations

- **Lightweight**: Menu bar app should have minimal memory footprint when idle
- **Responsive**: Menu should open instantly without lag
- **Background Processing**: Audio processing continues seamlessly in the background

## Technical Implementation Notes

### SwiftUI Menu Bar App

- Use `NSStatusBar.system.statusBar(withLength:)` to create the menu bar item
- Use `NSMenu` and `NSMenuItem` for the dropdown menu structure
- Remove `@main` from the window-based app structure
- Implement `NSApplicationDelegate` to manage the menu bar lifecycle

### Menu Updates

- Dynamically update device lists when audio devices are connected/disconnected
- Refresh HRIR preset list when files are added/removed from the directory
- Update checkmarks and states in real-time as user makes selections

### Integration with Existing Code

- Leverage existing `AudioDevice.swift` for device enumeration
- Use existing `HRIRManager.swift` for HRIR loading and processing
- Utilize `SettingsManager.swift` for state persistence
- Maintain existing audio processing pipeline

## User Experience Goals

1. **Simplicity**: All essential controls accessible from a single menu
2. **Discoverability**: Clear menu structure with logical grouping
3. **Efficiency**: Quick access to common tasks (toggle convolution, switch presets)
4. **Non-intrusive**: No window clutter, stays out of the way until needed
5. **Professional**: Clean, native macOS menu bar experience

## Future Enhancements (Optional)

- **Quick Actions**: Keyboard shortcuts for common operations
- **Advanced Settings**: Separate preferences window for detailed configuration
- **Status Display**: Show current audio levels or processing status in menu
- **Multiple Profiles**: Save and switch between different configuration profiles
