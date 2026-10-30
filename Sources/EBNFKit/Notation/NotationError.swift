/// Text that is not a grammar in the EBNF notation of XML 1.0 §6.
public struct NotationError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The 1-based line of the text where the error was found.
    public var line: Int

    /// The 1-based column, in Unicode scalars, where the error was found.
    public var column: Int

    /// What the parser expected or rejected.
    public var message: String

    /// Creates a notation error.
    public init(line: Int, column: Int, message: String) {
        self.line = line
        self.column = column
        self.message = message
    }

    public var description: String { "\(line):\(column): \(message)" }
}
