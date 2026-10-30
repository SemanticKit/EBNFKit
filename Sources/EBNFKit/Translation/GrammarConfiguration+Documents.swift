import Crypto
import Foundation

extension GrammarConfiguration {
    /// The grammar the configuration's documents hold, read from
    /// `directory`, where the documents are kept byte for byte.
    ///
    /// - Throws: ``TranslationError`` when a document cannot be read, its
    ///   bytes do not have the SHA-256 digest the configuration records for
    ///   it, it is not UTF-8, or its productions are not in the EBNF
    ///   notation.
    public func grammar(in directory: URL) throws(TranslationError) -> Grammar {
        var productions: [Production] = []
        for document in documents {
            let bytes: Data
            do {
                bytes = try Data(contentsOf: directory.appending(path: document.file))
            } catch {
                throw TranslationError("cannot read \(document.file): \(error.localizedDescription)")
            }
            productions += try document.grammar(from: bytes).productions
        }
        return Grammar(productions: productions)
    }
}

extension GrammarConfiguration.Document {
    /// The grammar in `bytes`, the document's bytes.
    ///
    /// - Throws: ``TranslationError`` when the bytes do not have the
    ///   document's ``sha256`` digest, are not UTF-8, or do not hold
    ///   productions in the EBNF notation.
    public func grammar(from bytes: Data) throws(TranslationError) -> Grammar {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == sha256.lowercased() else {
            throw TranslationError("\(file) has the SHA-256 digest \(digest), not the \(sha256) recorded for \(url): the published document must be kept byte for byte")
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw TranslationError("\(file) is not UTF-8")
        }
        do {
            switch format {
            case .notation: return try Grammar(notation: text)
            case .scraps: return try Grammar(scrapsIn: text)
            }
        } catch {
            throw TranslationError("\(file):\(error)")
        }
    }
}
