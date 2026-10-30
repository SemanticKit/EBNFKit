/// How one grammar is translated into Swift: its name, the published
/// documents its productions come from, and the conventions its
/// specification states in prose rather than in EBNF.
///
/// The configuration is the JSON file next to the grammar documents, named
/// `<name>.grammar.json`:
///
///     {
///       "name": "Turtle",
///       "documents": [{
///         "file": "turtle.bnf",
///         "url": "https://www.w3.org/TR/rdf12-turtle/turtle.bnf",
///         "retrieved": "2026-10-30",
///         "sha256": "f41c7cca08fd25ab2bdfa7edce8bb638f362c44599320d3f4ae9205c454e1d16"
///       }],
///       "caseInsensitiveStrings": "quotationMark"
///     }
public struct GrammarConfiguration: Sendable, Hashable, Codable {
    /// The grammar's name; the translation is the namespace `<name>Grammar`.
    public var name: String

    /// The published documents that hold the productions, in order. When
    /// two documents define a symbol, the first definition is used.
    public var documents: [Document]

    /// The quote whose strings match without regard to case, when the
    /// specification makes some strings case-insensitive. RDF 1.2 Turtle
    /// §6.5: "Keywords in quotation marks ("BASE", "PREFIX", and "VERSION")
    /// are case-insensitive."
    public var caseInsensitiveStrings: Expression.Quote?

    /// The productions to translate, with every production they refer to.
    /// `nil` translates every production of the documents.
    public var roots: [String]?

    /// Creates a configuration.
    public init(
        name: String,
        documents: [Document],
        caseInsensitiveStrings: Expression.Quote? = nil,
        roots: [String]? = nil
    ) {
        self.name = name
        self.documents = documents
        self.caseInsensitiveStrings = caseInsensitiveStrings
        self.roots = roots
    }

    /// A published document a grammar is read from, kept byte for byte.
    public struct Document: Sendable, Hashable, Codable {
        /// The file name of the document, next to the configuration.
        public var file: String

        /// Where the document is published.
        public var url: String

        /// The day the document was retrieved from `url`, `YYYY-MM-DD`.
        public var retrieved: String

        /// The SHA-256 digest of the document's bytes, in lowercase
        /// hexadecimal. The translator refuses a document whose bytes do
        /// not have this digest.
        public var sha256: String

        /// How the document holds its productions.
        public var format: Format

        /// Creates a document description.
        public init(file: String, url: String, retrieved: String, sha256: String, format: Format = .notation) {
            self.file = file
            self.url = url
            self.retrieved = retrieved
            self.sha256 = sha256
            self.format = format
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            file = try container.decode(String.self, forKey: .file)
            url = try container.decode(String.self, forKey: .url)
            retrieved = try container.decode(String.self, forKey: .retrieved)
            sha256 = try container.decode(String.self, forKey: .sha256)
            format = try container.decodeIfPresent(Format.self, forKey: .format) ?? .notation
        }
    }

    /// How a published document holds a grammar's productions.
    public enum Format: String, Sendable, Hashable, Codable {
        /// A text file in the EBNF notation of XML 1.0 §6
        /// (``Grammar/init(notation:)``), such as the RDF grammars'
        /// `turtle.bnf`.
        case notation
        /// A W3C specification in HTML whose productions are in
        /// `scrap` tables, as the XML 1.0 and Namespaces in XML
        /// Recommendations are (``Grammar/init(scrapsIn:)``).
        case scraps
    }
}
