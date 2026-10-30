/// A character class of the EBNF notation of XML 1.0 §6: `[a-zA-Z]`,
/// `[#xN-#xN]`, `[abc]`, `[#xN#xN]`, and each of these negated with `^`.
///
/// Inside the brackets every character stands for itself, except `#xN`,
/// which names a code point, and `-` between two members, which makes a
/// range. The notation has no escapes, so `[^"\]` excludes `"` and `\`.
public struct CharacterClass: Sendable, Hashable {
    /// Whether the class is written `[^…]` and matches the characters
    /// outside its ranges.
    public var isNegated: Bool

    /// The code point ranges the class lists, in the order written.
    public var ranges: [ClosedRange<UInt32>]

    /// Creates a character class.
    public init(isNegated: Bool, ranges: [ClosedRange<UInt32>]) {
        self.isNegated = isNegated
        self.ranges = ranges
    }

    /// Whether the class matches the character `scalar`.
    public func contains(_ scalar: Unicode.Scalar) -> Bool {
        ranges.contains { $0.contains(scalar.value) } != isNegated
    }
}
