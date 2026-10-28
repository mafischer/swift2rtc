import Foundation

/// The answers of cameras, read by local name: every vendor picks its own prefixes (`s:`, `SOAP-ENV:`, `env:`, none), so
/// elements are matched without the namespace prefix. Documents with a DOCTYPE are refused: no entities, no external
/// resources.
public enum SoapXML {
    /// Parses `text`; throws `OnvifError.invalidResponse` when it is not well-formed XML
    public static func parse(_ text: String) throws -> SoapElement {
        let source = String(text.drop { $0 == "\u{FEFF}" || $0.isWhitespace })
        if source.isEmpty { throw OnvifError.invalidResponse("empty") }
        if source.range(of: "<!DOCTYPE", options: .caseInsensitive) != nil { throw OnvifError.invalidResponse("doctype") }
        let builder = Builder()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw OnvifError.invalidResponse("xml") }
        return root
    }

    /// Escapes a value for an element's text or an attribute (user names and profile tokens go into the envelope)
    public static func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(character)
            }
        }
        return out
    }

    private final class Builder: NSObject, XMLParserDelegate {
        private var stack: [SoapElement] = []
        var root: SoapElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict { attributes[SoapElement.local(key)] = value }
            let element = SoapElement(name: SoapElement.local(elementName), attributes: attributes)
            stack.last?.append(.element(element))
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let element = stack.removeLast()
            if stack.isEmpty { root = element }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            stack.last?.append(.text(String(decoding: CDATABlock, as: UTF8.self)))
        }
    }
}

/// An element of a parsed answer, looked up by local name. Built once by `SoapXML.parse`, read-only afterwards.
public final class SoapElement: @unchecked Sendable {
    enum Content {
        case text(String)
        case element(SoapElement)
    }

    /// The name without its prefix
    public let name: String
    private let attributes: [String: String]
    private var content: [Content] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    fileprivate func append(_ item: Content) {
        content.append(item)
    }

    /// `name` without its namespace prefix (`tt:Uri` → `Uri`)
    public static func local(_ name: String) -> String {
        name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
    }

    /// The text content of this element and its descendants, trimmed
    public var text: String { rawText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var rawText: String {
        content.map { item in
            switch item {
            case .text(let text): text
            case .element(let element): element.rawText
            }
        }.joined()
    }

    /// The child elements in document order
    public var children: [SoapElement] {
        content.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// The attribute `name`, whatever its prefix
    public func attribute(_ name: String) -> String? { attributes[name] }

    /// The first child named `name`
    public func child(_ name: String) -> SoapElement? { children.first { $0.name == name } }

    /// Every child named `name`
    public func children(_ name: String) -> [SoapElement] { children.filter { $0.name == name } }

    /// The first element named `name` below this one, depth first
    public func descendant(_ name: String) -> SoapElement? { descendants(name).first }

    /// Every element named `name` below this one, in document order (not below a match)
    public func descendants(_ name: String) -> [SoapElement] {
        children.flatMap { $0.name == name ? [$0] : $0.descendants(name) }
    }

    /// The element at the path of child names, e.g. `path("Resolution", "Width")`
    public func path(_ names: String...) -> SoapElement? {
        names.reduce(self as SoapElement?) { current, name in current?.child(name) }
    }
}
