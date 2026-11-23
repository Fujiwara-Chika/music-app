import Foundation

/// Bundled demo library, matching the reference screenshot's content so the UI
/// can be inspected without importing a music folder. No audio is attached —
/// the transport falls back to a simulated clock for these rows.
enum DemoData {

    static let tracks: [Track] = dawn + live + daydream

    // MARK: DAWN (2015)

    private static let dawnTitles: [(Int, String, Int)] = [
        (1, "茜さす", 291),
        (2, "星屑", 254),
        (3, "Re:pray", 236),
        (4, "蝶々結び", 268),
        (5, "冬のダイヤモンド", 302),
        (6, "Open The Door", 244),
        (7, "悲しみの向こう側", 271),
        (8, "夏の匂い", 249),
        (9, "LAST STARDUST", 268),
        (10, "Brave Shine", 234),
        (11, "キズナ", 296),
        (12, "DAWN", 283),
        (13, "MOON RIVER", 259)
    ]

    private static let dawn: [Track] = dawnTitles.map { num, title, secs in
        var t = Track(
            title: title,
            artist: "Aimer",
            albumArtist: "Aimer",
            album: "DAWN",
            genre: "J-Pop",
            year: 2015,
            duration: TimeInterval(secs)
        )
        t.trackNumber = num
        t.codec = "AAC"
        t.profile = "LC"
        t.bitrate = 258
        t.playCount = title == "キズナ" ? 1 : 0
        t.rating = title == "キズナ" ? 0 : 0
        if title == "キズナ" {
            t.lyricist = "田中秀典"
            t.composer = "飛内将大"
            t.lyrics = [
                "たった一人で歩いてきた と思ったあの日",
                "本当はいつも どんな場面にも “誰か”",
                "がいたんだ",
                "過ぎてゆく日々"
            ]
            t.lastPlayed = Date()
        }
        return t
    }

    // MARK: Live at anywhere (2015)

    private static let liveTitles: [(Int, String, Int)] = [
        (1, "冬のダイヤモンド -Live ver.-", 318),
        (2, "Cold Sun -Live ver.-", 286),
        (3, "六等星の夜 -Live ver.-", 341)
    ]

    private static let live: [Track] = liveTitles.map { num, title, secs in
        var t = Track(
            title: title,
            artist: "Aimer",
            albumArtist: "Aimer",
            album: "Live at anywhere",
            genre: "J-Pop",
            year: 2015,
            duration: TimeInterval(secs)
        )
        t.trackNumber = num
        t.codec = "AAC"
        t.profile = "LC"
        t.bitrate = 256
        return t
    }

    // MARK: daydream (2016)

    private static let daydreamTitles: [(Int, String, Int)] = [
        (1, "insane dream", 245),
        (2, "ninelie with chelly (EGOIST)", 271),
        (3, "twoface", 233),
        (4, "Higher Ground", 258),
        (5, "for ロンリー with 阿部真央", 249),
        (6, "茜さす", 291),
        (7, "小さな部屋", 236),
        (8, "眩しくて", 264),
        (9, "ユメノツバサ", 251),
        (10, "花の唄", 302),
        (11, "春はゆく", 288),
        (12, "朝が来る", 243),
        (13, "蝶々結び", 268)
    ]

    private static let daydream: [Track] = daydreamTitles.map { num, title, secs in
        var t = Track(
            title: title,
            artist: "Aimer",
            albumArtist: "Aimer",
            album: "daydream",
            genre: "J-Pop",
            year: 2016,
            duration: TimeInterval(secs)
        )
        t.trackNumber = num
        t.codec = "AAC"
        t.profile = "LC"
        t.bitrate = 258
        return t
    }
}
