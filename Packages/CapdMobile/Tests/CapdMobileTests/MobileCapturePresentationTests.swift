import Testing

@testable import CapdMobile

@Test func unchangedAnnotationTagsKeepTheirOriginalSpellingAndBoundaries() {
    let original = ["MixedCase", "two words", " trailing "]
    let unchangedDraft = original.joined(separator: " ")

    #expect(
        MobileCapturePresentation.manualTagsToSave(
            draft: unchangedDraft, original: original) == original)
    #expect(
        MobileCapturePresentation.manualTagsToSave(
            draft: "MixedCase second", original: original) == ["mixedcase", "second"])
}

@Test func rowsDescribeImageTextAndLinkCapturesAccurately() {
    let image = MobileCapture(kind: .image, title: "Photo")
    let text = MobileCapture(kind: .text, title: "Note")
    let link = MobileCapture(kind: .link, url: "https://example.com/guide", title: "Guide")

    #expect(MobileCapturePresentation.symbol(for: image) == "photo")
    #expect(MobileCapturePresentation.metadata(for: image) == "image")
    #expect(MobileCapturePresentation.symbol(for: text) == "text.alignleft")
    #expect(MobileCapturePresentation.metadata(for: text) == "text · 0 chars")
    #expect(MobileCapturePresentation.symbol(for: link) == "link")
    #expect(MobileCapturePresentation.metadata(for: link) == "example.com/guide")
}

@Test func recognizedTextPreservesNonemptyOCRAndOmitsEmptyOCR() {
    var image = MobileCapture(kind: .image, title: "Board")
    #expect(MobileCapturePresentation.recognizedText(for: image) == nil)

    image.ocrText = "Design review at 2 pm"
    #expect(MobileCapturePresentation.recognizedText(for: image) == "Design review at 2 pm")

    image.ocrText = ""
    #expect(MobileCapturePresentation.recognizedText(for: image) == nil)
}
