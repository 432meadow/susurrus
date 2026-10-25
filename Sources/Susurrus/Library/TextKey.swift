import Foundation

/// The one way text is folded for comparing: search, sorting, artist names, duplicates and
/// release titles all treat "Björk", "BJORK" and "Bjork" as the same.
enum TextKey {
    /// Case, accents and full-/half-width forms folded away.
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// `folded`, keeping only letters and digits ("AC/DC" → "acdc").
    static func alphanumerics(_ text: String) -> String {
        String(String.UnicodeScalarView(folded(text).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    /// `folded`, with every run of anything but letters and digits turned into one space
    /// ("Ain't It Fun?" → "ain t it fun").
    static func words(_ text: String) -> String {
        let kept = folded(text).unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(kept).split(separator: " ").joined(separator: " ")
    }
}
