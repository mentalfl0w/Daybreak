import DaybreakCore
import Foundation
import Testing
@testable import Daybreak

@Suite("Menu bar story text")
struct MenuBarStoryTextTests {
    private func story(
        title: String? = nil,
        headline: String? = nil,
        body: String? = nil,
        quickFact: String? = nil,
        copyright: String? = nil
    ) -> StoryText {
        StoryText(
            title: title,
            headline: headline,
            body: body,
            quickFact: quickFact,
            copyright: copyright,
            sourceURL: nil,
            locale: "zh-CN",
            fetchedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("headline duplicating the title never hides the quick fact")
    func duplicateHeadlineUsesQuickFact() {
        let panel = StoryPanel.available(
            story(
                title: "秋日的保护色",
                headline: "秋日的保护色",
                body: "红松鼠是英国唯一的本土松鼠物种，在苏格兰的凯恩戈姆斯国家公园繁衍生息。",
                quickFact: "英国约八成的现存红松鼠生活在苏格兰；它们用树枝交织成巢，内部铺上树叶。"
            )
        )
        #expect(
            MenuBarStoryText.line(for: panel)
                == "英国约八成的现存红松鼠生活在苏格兰；它们用树枝交织成巢，内部铺上树叶。"
        )
    }

    @Test("headline duplicating the title never hides the description body")
    func duplicateHeadlineUsesBody() {
        let panel = StoryPanel.available(
            story(
                title: "秋日的保护色",
                headline: "秋日的保护色",
                body: "红松鼠是英国唯一的本土松鼠物种，在苏格兰的凯恩戈姆斯国家公园繁衍生息。这座公园是它们的重要庇护地。"
            )
        )
        #expect(
            MenuBarStoryText.line(for: panel)
                == "红松鼠是英国唯一的本土松鼠物种，在苏格兰的凯恩戈姆斯国家公园繁衍生息。"
        )
    }

    @Test("headline-only story does not masquerade as the introduction body")
    func headlineOnlyDoesNotStandInForBody() {
        let panel = StoryPanel.available(
            story(
                title: "秋日的保护色",
                headline: "秋日的保护色",
                copyright: "© Scotland: The Big Picture/Minden Pictures"
            )
        )
        #expect(MenuBarStoryText.line(for: panel) == "来源未返回可读的介绍正文。")
    }

    @Test("unavailable story never invents copy from title or copyright")
    func unavailableFallback() {
        let panel = StoryPanel.unavailable(
            reason: .fetchFailed,
            title: "红松鼠，凯恩戈姆斯国家公园，苏格兰高地",
            headline: nil,
            copyright: "© Scotland: The Big Picture/Minden Pictures",
            sourceURL: URL(string: "https://www.bing.com")
        )
        #expect(MenuBarStoryText.line(for: panel) == "该地区暂无可用介绍。")
    }

    @Test("unmatched candidates are hidden instead of borrowed")
    func unmatched() {
        #expect(
            MenuBarStoryText.line(for: .unmatched(hasCandidates: true))
                == "无法确认这段介绍属于这张图片，已隐藏。"
        )
    }

    @Test("long source text truncates with an ellipsis")
    func truncation() {
        let text = String(repeating: "山", count: 130)
        let result = MenuBarStoryText.firstSentence(in: text, limit: 10)
        #expect(result?.hasSuffix("…") == true)
        #expect(result?.count == 11)
    }
}
