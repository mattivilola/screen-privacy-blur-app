import Foundation

public enum CoverMessage {
    public static let maximumCharacters = 120
    public static let defaultText = "Screen Privacy"

    public static func normalized(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maximumCharacters))
    }

    public static func displayText(_ text: String) -> String {
        let message = normalized(text)
        return message.isEmpty ? defaultText : message
    }
}
