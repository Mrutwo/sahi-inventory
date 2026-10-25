import Foundation

/// Decoder for backend responses. Postgres timestamps arrive as ISO 8601 with
/// 0–6 fractional digits and an offset ("2026-10-25T18:20:31.123456+00:00");
/// this parser accepts all of those forms.
enum JSONCoding {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseTimestamp(raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognised date: \(raw)")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        // Postgres may use a space instead of "T".
        if value.count > 10, value[value.index(value.startIndex, offsetBy: 10)] == " " {
            value.replaceSubrange(value.index(value.startIndex, offsetBy: 10)...value.index(value.startIndex, offsetBy: 10), with: "T")
        }

        // Split off fractional seconds, which ISO8601DateFormatter handles poorly beyond 3 digits.
        var fraction: Double = 0
        if let dot = value.firstIndex(of: ".") {
            let afterDot = value.index(after: dot)
            let digitsEnd = value[afterDot...].firstIndex(where: { !$0.isNumber }) ?? value.endIndex
            let digits = value[afterDot..<digitsEnd]
            if !digits.isEmpty {
                fraction = Double("0." + digits) ?? 0
            }
            value.removeSubrange(dot..<digitsEnd)
        }
        // "+00" → "+00:00"
        if let signIndex = value.lastIndex(where: { $0 == "+" || $0 == "-" }),
           value.distance(from: value.startIndex, to: signIndex) > 10 {
            let offset = value[value.index(after: signIndex)...]
            if offset.count == 2 { value += ":00" }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let base = formatter.date(from: value) else { return nil }
        return base.addingTimeInterval(fraction)
    }
}
