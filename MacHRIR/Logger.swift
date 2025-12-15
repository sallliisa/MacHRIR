import Foundation

enum Logger {
    static func log(_ items: Any..., separator: String = " ", terminator: String = "\n") {
        #if DEBUG
        let output = items.map { "\($0)" }.joined(separator: separator)
        print(output, terminator: terminator)
        #endif
    }
}
