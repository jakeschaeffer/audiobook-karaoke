import Foundation

/// Turns an epub spine document (XHTML) into plain prose for alignment.
///
/// Lives in this package — not the app — because it is pure string processing and the aligner's
/// tests need to exercise it without Readium. The app side only walks the publication's reading
/// order and hands each document's markup here.
///
/// This is deliberately a tag stripper, not an XML parser: spine documents in the wild carry
/// unclosed tags, bare ampersands, and namespace soup that a strict parser rejects, and the
/// aligner downstream only needs word-and-sentence fidelity, not structure. Block-level tags
/// become newlines so sentence splitting can treat element boundaries as hard breaks.
public enum EbookHTML {
  /// Plain text of one XHTML document: tags stripped, entities decoded, block boundaries as
  /// newlines, whitespace collapsed.
  public static func plainText(fromXHTML markup: String) -> String {
    var out = ""
    out.reserveCapacity(markup.count / 2)

    var index = markup.startIndex
    var skippingUntil: String? = nil  // lowercase closing tag we're discarding content to

    while index < markup.endIndex {
      let character = markup[index]
      if character == "<" {
        guard let close = markup[index...].firstIndex(of: ">") else { break }
        let tag = markup[markup.index(after: index)..<close]
        let name = tagName(of: tag)

        if let waiting = skippingUntil {
          if name == waiting, tag.first == "/" { skippingUntil = nil }
        } else if ["script", "style", "head", "svg"].contains(name), tag.first != "/",
          tag.last != "/"
        {
          skippingUntil = name
        } else if name == "br" || blockTags.contains(name) {
          out.append("\n")
        }
        index = markup.index(after: close)
        continue
      }

      if skippingUntil == nil {
        if character == "&" {
          let (scalar, next) = decodeEntity(markup, from: index)
          out.append(scalar)
          index = next
          continue
        }
        out.append(character)
      }
      index = markup.index(after: index)
    }

    return collapse(out)
  }

  /// Join spine documents in reading order. Document boundaries are paragraph breaks — a chapter
  /// never ends mid-sentence, and the hard break keeps the sentence splitter from gluing a
  /// chapter's last line to the next chapter's heading.
  public static func joinDocuments(_ documents: [String]) -> String {
    documents
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  private static let blockTags: Set<String> = [
    "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ul", "ol", "tr", "td", "th",
    "table", "blockquote", "section", "article", "header", "footer", "figure", "figcaption",
    "hr", "dt", "dd", "aside", "nav", "pre",
  ]

  private static func tagName(of tag: Substring) -> String {
    var body = tag
    if body.first == "/" { body = body.dropFirst() }
    let name = body.prefix { $0.isLetter || $0.isNumber }
    return name.lowercased()
  }

  /// Decode one entity starting at `&`. Returns the decoded text and the index to resume from;
  /// a malformed entity comes back as the literal `&` so nothing is ever dropped.
  private static func decodeEntity(
    _ markup: String,
    from start: String.Index
  ) -> (
    String, String.Index
  ) {
    let limit = markup.index(start, offsetBy: 12, limitedBy: markup.endIndex) ?? markup.endIndex
    guard let semicolon = markup[start..<limit].firstIndex(of: ";") else {
      return ("&", markup.index(after: start))
    }
    let body = markup[markup.index(after: start)..<semicolon]
    let after = markup.index(after: semicolon)

    if body.first == "#" {
      let digits = body.dropFirst()
      let value =
        digits.first == "x" || digits.first == "X"
        ? UInt32(digits.dropFirst(), radix: 16)
        : UInt32(digits)
      if let value, let scalar = Unicode.Scalar(value) {
        return (String(Character(scalar)), after)
      }
      return ("&", markup.index(after: start))
    }

    if let known = namedEntities[String(body)] {
      return (known, after)
    }
    return ("&", markup.index(after: start))
  }

  private static let namedEntities: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
    "nbsp": "\u{00A0}", "hellip": "…", "mdash": "—", "ndash": "–",
    "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
    "shy": "", "copy": "©", "reg": "®", "trade": "™", "sect": "§", "middot": "·",
  ]

  /// Collapse runs of spaces to one space and runs of newlines to one newline; NBSP becomes a
  /// plain space. Every block boundary emitted two newlines (close + open) — the sentence
  /// splitter downstream treats any newline as a hard break, so distinguishing single from
  /// double buys nothing.
  private static func collapse(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    var pendingNewline = false
    var pendingSpace = false

    for character in text {
      if character == "\n" || character == "\r" {
        pendingNewline = true
        pendingSpace = false
      } else if character == " " || character == "\t" || character == "\u{00A0}" {
        pendingSpace = true
      } else {
        if pendingNewline, !out.isEmpty {
          out.append("\n")
        } else if pendingSpace, !out.isEmpty {
          out.append(" ")
        }
        pendingNewline = false
        pendingSpace = false
        out.append(character)
      }
    }
    return out
  }
}
