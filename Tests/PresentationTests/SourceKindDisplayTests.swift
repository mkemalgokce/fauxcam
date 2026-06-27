import Testing
@testable import Presentation

struct SourceKindDisplayTests {
    @Test func everyKindHasNonEmptyDisplayStrings() {
        for kind in SessionModel.SourceKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.shortTitle.isEmpty)
            #expect(!kind.symbol.isEmpty)
            #expect(!kind.footerHint.isEmpty)
            #expect(kind.supportsFraming)
        }
    }

    @Test func onlyVideoAndQrNeedDetail() {
        #expect(SessionModel.SourceKind.video.needsDetail)
        #expect(SessionModel.SourceKind.qr.needsDetail)
        #expect(!SessionModel.SourceKind.image.needsDetail)
        #expect(!SessionModel.SourceKind.webcam.needsDetail)
    }

    @Test func titlesAreDistinctPerKind() {
        let titles = SessionModel.SourceKind.allCases.map(\.title)
        #expect(Set(titles).count == titles.count)
    }
}
