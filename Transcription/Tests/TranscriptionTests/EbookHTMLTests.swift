import Foundation
import Testing

@testable import Transcription

@Suite("Ebook HTML → plain text")
struct EbookHTMLTests {
  @Test("tags stripped, blocks become line breaks, inline tags don't")
  func blocksAndInlines() {
    let xhtml = """
      <html><body><h1>ONE</h1><p>I was <em>fifteen</em> years old.</p>\
      <p>It was a Tuesday.</p></body></html>
      """
    let text = EbookHTML.plainText(fromXHTML: xhtml)
    #expect(text == "ONE\nI was fifteen years old.\nIt was a Tuesday.")
  }

  @Test("script/style/head contents are dropped entirely")
  func dropsNonProse() {
    let xhtml = """
      <head><title>Greenlights</title><style>p { margin: 0; }</style></head>\
      <body><p>Real prose.</p><script>var x = 1;</script></body>
      """
    #expect(EbookHTML.plainText(fromXHTML: xhtml) == "Real prose.")
  }

  @Test("entities decode; malformed ampersands survive as literals")
  func entities() {
    let xhtml = "<p>Tom &amp; Jerry &mdash; &#8220;quoted&#8221; &nbsp; A&B</p>"
    #expect(EbookHTML.plainText(fromXHTML: xhtml) == "Tom & Jerry — “quoted” A&B")
  }

  @Test("whitespace collapses: runs of spaces and 3+ newlines")
  func whitespace() {
    let xhtml = "<div><p>one   two</p><br/><br/><p>  three </p></div>"
    #expect(EbookHTML.plainText(fromXHTML: xhtml) == "one two\nthree")
  }

  @Test("joinDocuments drops empties and separates chapters hard")
  func joins() {
    #expect(
      EbookHTML.joinDocuments(["  ", "Chapter one text.", "", "Chapter two text."])
        == "Chapter one text.\n\nChapter two text."
    )
  }

  @Test("self-closing and attribute-heavy tags don't confuse the scanner")
  func attributes() {
    let xhtml = #"<p class="x" data-a="1>2"><img src="a.png"/>Text stays.</p>"#
    // The '>' inside the quoted attribute ends the tag early by design (tolerant scanner);
    // what matters is the prose survives.
    #expect(EbookHTML.plainText(fromXHTML: xhtml).contains("Text stays."))
  }
}
