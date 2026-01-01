//
//  ConfigurationManager.swift
//  Airwave
//
//  Manages application configuration from Configuration.plist
//

import Foundation

/// Manages application configuration loaded from Configuration.plist
enum ConfigurationManager {
    
    /// External URLs used in the application
    enum ExternalLinks {
        private static let config = ConfigurationManager.loadConfiguration()
        
        /// BlackHole virtual audio driver download page
        static var blackHoleDownload: URL {
            guard let urlString = config["ExternalLinks"]?["BlackHoleDownload"] as? String,
                  let url = URL(string: urlString) else {
                fatalError("Invalid or missing BlackHoleDownload URL in Configuration.plist")
            }
            return url
        }
        
        /// HRTF Database (Airtable)
        static var hrtfDatabase: URL {
            guard let urlString = config["ExternalLinks"]?["HRTFDatabase"] as? String,
                  let url = URL(string: urlString) else {
                fatalError("Invalid or missing HRTFDatabase URL in Configuration.plist")
            }
            return url
        }
        
        /// Setup guide (GitHub)
        static var setupGuide: URL {
            guard let urlString = config["ExternalLinks"]?["SetupGuide"] as? String,
                  let url = URL(string: urlString) else {
                fatalError("Invalid or missing SetupGuide URL in Configuration.plist")
            }
            return url
        }
    }
    
    // MARK: - Private Methods
    
    /// Load configuration from Configuration.plist
    private static func loadConfiguration() -> [String: [String: Any]] {
        guard let path = Bundle.main.path(forResource: "Configuration", ofType: "plist"),
              let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            fatalError("Configuration.plist not found or invalid format")
        }
        
        // Convert to typed dictionary
        var config: [String: [String: Any]] = [:]
        for (key, value) in plist {
            if let dict = value as? [String: Any] {
                config[key] = dict
            }
        }
        
        return config
    }
}
