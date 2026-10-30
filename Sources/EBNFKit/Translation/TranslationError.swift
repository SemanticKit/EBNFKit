/// A grammar that cannot be translated into Swift.
public struct TranslationError: Error, Sendable, Hashable, CustomStringConvertible {
    /// Why the grammar cannot be translated.
    public var message: String

    /// Creates a translation error.
    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
