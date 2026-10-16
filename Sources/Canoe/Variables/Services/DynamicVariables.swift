import Foundation

/// Postman's dynamic variables: `{{$guid}}`, `{{$timestamp}}`, … generate a
/// fresh value when a request is resolved, so temporary values never need a
/// real variable definition.
///
/// Each occurrence in one request evaluates separately (two `{{$guid}}`
/// placeholders in one send produce two different GUIDs), exactly like
/// Postman. User-defined variables always win: `VariableResolver` only
/// consults this registry when the key is not in scope, so an environment
/// can pin `{{$randomEmail}}` to a fixed value for reproducible sends.
enum DynamicVariables {
    /// One dynamic variable: its `$key` (the completion candidate and the
    /// exact resolver key), a one-line explanation shown by the Help sheet
    /// and the completion tooltip, and the generator. Generators only touch
    /// the immutable pools below, so the type is trivially sendable.
    struct Entry: Sendable {
        let key: String
        let summary: String
        let generate: @Sendable () -> String
    }

    /// The curated core of Postman's dynamic list - identity/time/data
    /// generators an API client reaches for daily. Keys are matched
    /// case-sensitively, like Postman's. The Help sheet (Help ▸ Dynamic
    /// Variables) renders this list as-is, so new entries need no UI work.
    static let entries: [Entry] = [
        Entry(key: "$guid", summary: "A fresh UUID v4 every time it resolves") {
            UUID().uuidString.lowercased()
        },
        Entry(key: "$timestamp", summary: "Current UNIX timestamp, in seconds") {
            String(Int(Date().timeIntervalSince1970))
        },
        Entry(
            key: "$isoTimestamp",
            summary: "Current UTC timestamp, ISO 8601 with milliseconds"
        ) {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date())
        },
        Entry(key: "$randomInt", summary: "Random integer between 0 and 1000") {
            String(Int.random(in: 0...1000))
        },
        Entry(key: "$randomBoolean", summary: "Random true or false") {
            Bool.random() ? "true" : "false"
        },
        Entry(key: "$randomAlphaNumeric", summary: "One random letter or digit") {
            let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return String(pool.randomElement() ?? "a")
        },
        Entry(key: "$randomFirstName", summary: "Random first name") {
            Self.firstNamePool.randomElement() ?? "Ada"
        },
        Entry(key: "$randomLastName", summary: "Random last name") {
            Self.lastNamePool.randomElement() ?? "Lovelace"
        },
        Entry(key: "$randomFullName", summary: "Random first and last name") {
            "\(Self.firstNamePool.randomElement() ?? "Ada") \(Self.lastNamePool.randomElement() ?? "Lovelace")"
        },
        Entry(
            key: "$randomEmail",
            summary: "Random email address on an example.com domain"
        ) {
            let first = (Self.firstNamePool.randomElement() ?? "ada").lowercased()
            let last = (Self.lastNamePool.randomElement() ?? "lovelace").lowercased()
            let domain = Self.domainPool.randomElement() ?? "example.com"
            return "\(first).\(last)@\(domain)"
        },
        Entry(
            key: "$randomPassword",
            summary: "Random 16-character password with special characters"
        ) {
            let pool = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789!@#$%^&*")
            return String((0..<16).map { _ in pool.randomElement() ?? "a" })
        },
        Entry(key: "$randomColor", summary: "Random color name") {
            Self.colorNamePool.randomElement() ?? "blue"
        },
        Entry(key: "$randomCity", summary: "Random city name") {
            Self.cityPool.randomElement() ?? "Zurich"
        },
        Entry(key: "$randomCountry", summary: "Random country name") {
            Self.countryPool.randomElement() ?? "Switzerland"
        },
        Entry(key: "$randomPhoneNumber", summary: "Random 10-digit phone number") {
            let digits = (0..<10).map { _ in String(Int.random(in: 0...9)) }.joined()
            let area = digits.prefix(3)
            let exchange = digits.dropFirst(3).prefix(3)
            let line = digits.suffix(4)
            return "\(area)-\(exchange)-\(line)"
        },
        Entry(key: "$randomURL", summary: "Random URL on a fake domain") {
            let host = (Self.lastNamePool.randomElement() ?? "lovelace").lowercased()
            return "https://www.\(host)\(Self.domainSuffixPool.randomElement() ?? ".com")"
        },
        Entry(key: "$randomIPAddress", summary: "Random IPv4 address") {
            "\(Int.random(in: 1...254)).\(Int.random(in: 0...255)).\(Int.random(in: 0...255)).\(Int.random(in: 1...254))"
        },
        Entry(key: "$randomCurrencyCode", summary: "Random ISO 4217 currency code") {
            Self.currencyCodePool.randomElement() ?? "USD"
        },
        Entry(key: "$randomLoremWord", summary: "Random lorem ipsum word") {
            Self.loremWordPool.randomElement() ?? "lorem"
        },
        Entry(key: "$randomLoremSentence", summary: "Random lorem ipsum sentence") {
            let count = Int.random(in: 6...12)
            let words = (0..<count).map { _ in Self.loremWordPool.randomElement() ?? "lorem" }
            var sentence = words.joined(separator: " ")
            sentence = sentence.prefix(1).capitalized + sentence.dropFirst()
            return sentence + "."
        },
    ]

    /// Lookup by exact key (`$guid`). The dictionary is built once; entries
    /// are compile-time constants, so keys cannot collide.
    private static let byKey: [String: Entry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    }()

    /// Whether a placeholder key is a dynamic variable (its `$` prefix).
    /// Used to keep `{{$guid}}` out of the unresolved-variables warning -
    /// dynamic keys always resolve.
    static func isDynamic(_ key: String) -> Bool {
        key.hasPrefix("$")
    }

    /// A fresh value for `$key`, or nil when the key is not one.
    static func value(for key: String) -> String? {
        byKey[key]?.generate()
    }

    // MARK: - Data pools

    private static let firstNamePool = [
        "Ada", "Grace", "Alan", "Edsger", "Barbara", "Donald", "Radia", "Tim",
        "Margaret", "Dennis", "Frances", "Ken", "Anita", "Linus", "Sophie", "James",
        "Rosa", "Marvin", "Hedy", "Claude", "Katherine", "John", "Mary", "Richard",
    ]
    private static let lastNamePool = [
        "Lovelace", "Turing", "Hopper", "Dijkstra", "Liskov", "Knuth", "Perlman",
        "Berners-Lee", "Hamilton", "Ritchie", "Allen", "Thompson", "Borg", "Torvalds",
        "Wilson", "Gosling", "Johnson", "Minsky", "Lamarr", "Shannon", "Johnson",
        "Backus", "Keller", "Stallman",
    ]
    private static let domainSuffixPool = [".com", ".net", ".org", ".io", ".dev"]
    private static let domainPool = [
        "example.com", "example.net", "example.org",
        "test.example.com", "api.example.com", "staging.example.net",
    ]
    private static let colorNamePool = [
        "blue", "red", "green", "yellow", "magenta", "cyan", "orange", "purple",
        "teal", "pink", "brown", "black", "white", "gray", "navy", "lime",
    ]
    private static let cityPool = [
        "Zurich", "Berlin", "Amsterdam", "Kyoto", "Lisbon", "Toronto", "Denver",
        "Oslo", "Prague", "Vienna", "Barcelona", "Dublin", "Helsinki", "Seoul",
        "Singapore", "Austin", "Montreal", "Copenhagen",
    ]
    private static let countryPool = [
        "Switzerland", "Germany", "Netherlands", "Japan", "Portugal", "Canada",
        "United States", "Norway", "Czech Republic", "Austria", "Spain", "Ireland",
        "Finland", "South Korea", "Singapore", "Australia",
    ]
    private static let currencyCodePool = [
        "USD", "EUR", "GBP", "JPY", "CNY", "CHF", "CAD", "AUD", "SEK", "KRW",
    ]
    private static let loremWordPool = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing",
        "elit", "sed", "eiusmod", "tempor", "incididunt", "labore", "dolore",
        "magna", "aliqua", "enim", "minim", "veniam", "quis", "nostrud",
        "exercitation", "ullamco", "laboris",
    ]
}
