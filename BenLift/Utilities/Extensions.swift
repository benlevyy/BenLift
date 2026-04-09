import SwiftUI

// MARK: - Color Extensions

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }

    // App color palette — forest, cream, tan, sage
    static let pushBlue = Color(hex: "2D5F2D")      // forest green (primary)
    static let pullGreen = Color(hex: "6B8F5E")     // sage
    static let legsOrange = Color(hex: "C49A6C")    // tan
    static let cardSurface = Color(hex: "F3EDE4")   // warm cream
    static let appBackground = Color(hex: "FAF6F0")  // off-white cream
    static let secondaryText = Color(hex: "8C7B6B")  // warm brown
    static let prGreen = Color(hex: "4A7C3F")        // deep sage
    static let failedRed = Color(hex: "B54A4A")      // muted brick red
    static let accentBlue = Color(hex: "2D5F2D")     // forest green (accent)
}

// MARK: - Date Extensions

extension Date {
    var startOfWeek: Date {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: self)
        return calendar.date(from: components) ?? self
    }

    func daysSince(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: self).day ?? 0
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(self)
    }

    var weekdayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: self)
    }

    var shortFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: self)
    }

    var weekdayIndex: Int {
        // 1 = Sunday, 2 = Monday, ... 7 = Saturday
        Calendar.current.component(.weekday, from: self)
    }
}

// MARK: - Double Extensions

extension Double {
    func formattedWeight(unit: WeightUnit = .lbs) -> String {
        let converted = unit == .kg ? self * 0.453592 : self
        if converted.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(converted)) \(unit.displaySuffix)"
        }
        return String(format: "%.1f %@", converted, unit.displaySuffix)
    }

    var formattedReps: String {
        if self.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(self))"
        }
        // 4.5 means 4 completed + failed 5th
        return "\(Int(self))F"
    }
}

// MARK: - TimeInterval Extensions

extension TimeInterval {
    var formattedDuration: String {
        let totalSeconds = Int(self)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedMinSec: String {
        let totalSeconds = Int(self)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Data Extensions

extension Data {
    func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(type, from: self)
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(value)
    }
}
