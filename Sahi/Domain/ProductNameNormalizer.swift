import Foundation

/// Product-name normalization. `key(_:)` mirrors the server function
/// `public.normalize_product_name`, which is the authority on product
/// identity; the app uses it to detect existing products while typing and
/// for search.
enum ProductNameNormalizer {
    /// Display form: trimmed, inner whitespace collapsed to single spaces.
    static func displayName(_ raw: String) -> String {
        collapseWhitespace(raw)
    }

    /// Identity / search key: niqqud removed, quote marks unified,
    /// lower-cased, whitespace collapsed.
    static func key(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.value {
            case 0x0591...0x05BD, 0x05BF, 0x05C1, 0x05C2, 0x05C4, 0x05C5, 0x05C7:
                continue // Hebrew points and cantillation marks
            case 0x05F4, 0x201C, 0x201D:
                scalars.append("\"") // gershayim, typographic double quotes
            case 0x05F3, 0x2018, 0x2019:
                scalars.append("'") // geresh, typographic single quotes
            default:
                scalars.append(scalar)
            }
        }
        return collapseWhitespace(String(scalars).lowercased())
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
