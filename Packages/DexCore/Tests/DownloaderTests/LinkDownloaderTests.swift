@testable import Downloader
import Foundation
import Testing

@Suite("Link downloader")
struct LinkDownloaderTests {
    @Test("Recognises YouTube links", arguments: [
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "youtube.com/watch?v=dQw4w9WgXcQ&t=42",
        "https://youtu.be/dQw4w9WgXcQ",
        "https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RD",
        "https://www.youtube.com/shorts/abc123",
        "  https://m.youtube.com/watch?v=abc  ",
    ])
    func links(_ text: String) {
        #expect(LinkDownloader.link(in: text) != nil)
    }

    @Test("Rejects everything else", arguments: [
        "", "hello", "https://example.com/watch?v=x", "https://www.youtube.com/", "https://youtu.be/",
        "https://www.youtube.com/watch", "file:///etc/passwd", "https://youtube.com.evil.example/watch?v=x",
    ])
    func notLinks(_ text: String) {
        #expect(LinkDownloader.link(in: text) == nil)
    }

    @Test("Reads progress lines")
    func progress() {
        #expect(LinkDownloader.progress(in: "DEX  42.5%") == 0.425)
        #expect(LinkDownloader.progress(in: "DEX 100.0%") == 1)
        #expect(LinkDownloader.progress(in: "[youtube] Extracting URL") == nil)
    }

    @Test("Finds the binary's checksum in the release list")
    func checksum() {
        let sums = "aaa  yt-dlp\nBBB  yt-dlp_macos\nccc  yt-dlp_macos.zip\n"
        #expect(LinkDownloader.checksum(for: "yt-dlp_macos", in: sums) == "bbb")
        #expect(LinkDownloader.checksum(for: "missing", in: sums) == nil)
    }

    @Test("Reads title, artist and the AAC stream's bit rate from yt-dlp's JSON")
    func info() throws {
        let json = #"""
        {"title": "Big Buck Bunny", "uploader": "Blender", "duration": 634.5, "thumbnail": "https://i.ytimg.com/x.webp",
         "formats": [{"acodec": "mp4a.40.2", "vcodec": "none", "abr": 129.5}, {"acodec": "opus", "vcodec": "none", "abr": 160},
                     {"acodec": "mp4a.40.5", "vcodec": "none", "abr": 48}, {"acodec": "none", "vcodec": "avc1"}]}
        """#
        let info = try #require(LinkDownloader.parseInfo(Data(json.utf8)))
        #expect(info.title == "Big Buck Bunny")
        #expect(info.artist == "Blender")
        #expect(info.duration == 634.5)
        #expect(info.aacKbps == 130)
        #expect(LinkDownloader.thumbnailURL(Data(json.utf8))?.host() == "i.ytimg.com")
    }

    @Test("Explains common failures in plain words")
    func explain() {
        #expect(LinkDownloader.explain("ERROR: [youtube] x: Private video. Sign in").contains("private"))
        #expect(LinkDownloader.explain("ERROR: Requested format is not available").contains("AAC"))
    }
}
