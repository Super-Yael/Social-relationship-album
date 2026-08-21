import Foundation

struct ClassifiedSocialData: Equatable {
    var accounts: [(platform: String, value: String)]
    var unclassified: [String]

    static func == (lhs: ClassifiedSocialData, rhs: ClassifiedSocialData) -> Bool {
        lhs.accounts.map { "\($0.platform)\u{0}\($0.value)" }
            == rhs.accounts.map { "\($0.platform)\u{0}\($0.value)" }
            && lhs.unclassified == rhs.unclassified
    }
}

enum LegacySocialImporter {
    static func classify(_ rawValue: String) -> ClassifiedSocialData {
        let tokens = rawValue
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var accounts: [(platform: String, value: String)] = []
        var unclassified: [String] = []
        var seen = Set<String>()

        for token in tokens {
            let lower = token.lowercased()
            let platform: SocialPlatform?
            if lower.hasPrefix("wxid_") {
                platform = .wechat
            } else if token.range(of: #"^[0-9]{5,12}$"#, options: .regularExpression) != nil {
                platform = .qq
            } else if lower.contains("douyin.com") {
                platform = .douyin
            } else if lower.contains("x.com/") || lower.contains("twitter.com/") {
                platform = .x
            } else if lower.contains("t.me/") || token.hasPrefix("@") {
                platform = .telegram
            } else {
                platform = nil
            }

            if let platform {
                let key = "\(platform.rawValue)\u{0}\(token.lowercased())"
                if seen.insert(key).inserted {
                    accounts.append((platform.rawValue, token))
                }
            } else {
                unclassified.append(token)
            }
        }
        return ClassifiedSocialData(accounts: accounts, unclassified: unclassified)
    }
}
