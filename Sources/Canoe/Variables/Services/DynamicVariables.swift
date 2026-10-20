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
///
/// Keys are matched case-sensitively and are copied verbatim from Postman's
/// documented list (learning.postman.com, "Dynamic variables"), so muscle
/// memory from there types valid placeholders here. The one documented group
/// not implemented is Images: Postman serves those from lorempixel.com, a
/// dead service, and its URLs resolve to nothing (and `$randomImageDataUri`
/// would balloon a body). Postman's descriptions are the summaries of
/// record; the Help sheet (Help ▸ Dynamic Variables) renders `entries`
/// as-is, so new entries need no UI work.
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

    static let entries: [Entry] =
        common
        + textNumbersAndColors
        + internetAndIPAddresses
        + names
        + profession
        + phoneAddressAndLocation
        + finance
        + business
        + catchphrases
        + databases
        + dates
        + domainsEmailsUsernames
        + filesAndDirectories
        + stores
        + grammar
        + loremIpsum

    /// Lookup by exact key (`$guid`). The dictionary is built once; entries
    /// are compile-time constants, so keys cannot collide.
    private static let byKey: [String: Entry] = {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0) })
    }()

    /// Whether a placeholder key is a known dynamic variable. Registry
    /// membership, not just the `$` prefix: an unknown `$key` never
    /// resolves (it goes on the wire literally), so it must not be waved
    /// through the unresolved-variables warning - or tinted as resolved
    /// in the editors - only because of its prefix.
    static func isDynamic(_ key: String) -> Bool {
        byKey[key] != nil
    }

    /// A fresh value for `$key`, or nil when the key is not one.
    static func value(for key: String) -> String? {
        byKey[key]?.generate()
    }

    // MARK: - Common (Postman: identity & time)

    private static let common: [Entry] = [
        Entry(key: "$guid", summary: "A fresh UUID v4 every time it resolves") {
            UUID().uuidString.lowercased()
        },
        Entry(key: "$randomUUID", summary: "A random 36-character UUID") {
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
    ]

    // MARK: - Text, numbers, and colors

    private static let textNumbersAndColors: [Entry] = [
        Entry(key: "$randomAlphaNumeric", summary: "One random letter or digit") {
            let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            return String(pool.randomElement() ?? "a")
        },
        Entry(key: "$randomBoolean", summary: "Random true or false") {
            Bool.random() ? "true" : "false"
        },
        Entry(key: "$randomInt", summary: "Random integer between 0 and 1000") {
            String(Int.random(in: 0...1000))
        },
        Entry(key: "$randomColor", summary: "A random color name") {
            drawRandom(colorNamePool)
        },
        Entry(key: "$randomHexColor", summary: "A random hex color (#rrggbb)") {
            "#\(hexChars(6))"
        },
        Entry(key: "$randomAbbreviation", summary: "A random technical abbreviation") {
            drawRandom(abbreviationPool)
        },
    ]

    // MARK: - Internet and IP addresses

    private static let internetAndIPAddresses: [Entry] = [
        Entry(key: "$randomIP", summary: "A random IPv4 address") {
            [Int.random(in: 0...255), Int.random(in: 0...255), Int.random(in: 0...255), Int.random(in: 0...255)]
                .map(String.init)
                .joined(separator: ".")
        },
        Entry(key: "$randomIPV6", summary: "A random IPv6 address") {
            (0..<8).map { _ in hexChars(4) }.joined(separator: ":")
        },
        Entry(key: "$randomMACAddress", summary: "A random MAC address") {
            (0..<6).map { _ in hexChars(2) }.joined(separator: ":")
        },
        Entry(key: "$randomPassword", summary: "A random 15-character alphanumeric password") {
            alphanumeric(15, from: "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        },
        Entry(key: "$randomLocale", summary: "A random two-letter language code (ISO 639-1)") {
            drawRandom(localePool)
        },
        Entry(key: "$randomUserAgent", summary: "A random browser user-agent string") {
            drawRandom(userAgentPool)
        },
        Entry(key: "$randomProtocol", summary: "A random internet protocol (http/https)") {
            Bool.random() ? "https" : "http"
        },
        Entry(key: "$randomSemver", summary: "A random semantic version number") {
            "\(Int.random(in: 0...9)).\(Int.random(in: 0...9)).\(Int.random(in: 0...9))"
        },
    ]

    // MARK: - Names

    private static let names: [Entry] = [
        Entry(key: "$randomFirstName", summary: "A random first name") {
            drawRandom(firstNamePool)
        },
        Entry(key: "$randomLastName", summary: "A random last name") {
            drawRandom(lastNamePool)
        },
        Entry(key: "$randomFullName", summary: "A random first and last name") {
            "\(drawRandom(firstNamePool)) \(drawRandom(lastNamePool))"
        },
        Entry(key: "$randomNamePrefix", summary: "A random name prefix (Dr., Ms., Mr.)") {
            drawRandom(namePrefixPool)
        },
        Entry(key: "$randomNameSuffix", summary: "A random name suffix (PhD, III, MD)") {
            drawRandom(nameSuffixPool)
        },
    ]

    // MARK: - Profession

    private static let profession: [Entry] = [
        Entry(key: "$randomJobArea", summary: "A random job area") {
            drawRandom(jobAreaPool)
        },
        Entry(key: "$randomJobDescriptor", summary: "A random job descriptor") {
            drawRandom(jobDescriptorPool)
        },
        Entry(key: "$randomJobTitle", summary: "A random job title") {
            "\(drawRandom(jobDescriptorPool)) \(drawRandom(jobAreaPool)) \(drawRandom(jobTypePool))"
        },
        Entry(key: "$randomJobType", summary: "A random job type") {
            drawRandom(jobTypePool)
        },
    ]

    // MARK: - Phone, address, and location

    private static let phoneAddressAndLocation: [Entry] = [
        Entry(key: "$randomPhoneNumber", summary: "A random 10-digit phone number (555-000-0000)") {
            "\(digits(3))-\(digits(3))-\(digits(4))"
        },
        Entry(key: "$randomPhoneNumberExt", summary: "A random phone number with extension (12 digits)") {
            "\(digits(2))-\(digits(3))-\(digits(3))-\(digits(4))"
        },
        Entry(key: "$randomCity", summary: "A random city name") {
            drawRandom(cityPool)
        },
        Entry(key: "$randomStreetName", summary: "A random street name") {
            "\(drawRandom(lastNamePool)) \(drawRandom(streetSuffixPool))"
        },
        Entry(key: "$randomStreetAddress", summary: "A random street address") {
            "\(Int.random(in: 1...99_999)) \(drawRandom(lastNamePool)) \(drawRandom(streetSuffixPool))"
        },
        Entry(key: "$randomCountry", summary: "A random country name") {
            drawRandom(countryPool)
        },
        Entry(key: "$randomCountryCode", summary: "A random two-letter country code (ISO 3166-1 alpha-2)") {
            drawRandom(countryCodePool)
        },
        Entry(key: "$randomLatitude", summary: "A random latitude coordinate") {
            coordinate(-90...90)
        },
        Entry(key: "$randomLongitude", summary: "A random longitude coordinate") {
            coordinate(-180...180)
        },
    ]

    // MARK: - Finance

    private static let finance: [Entry] = [
        Entry(key: "$randomBankAccount", summary: "A random 8-digit bank account number") {
            digits(8)
        },
        Entry(key: "$randomBankAccountName", summary: "A random bank account name") {
            drawRandom(bankAccountNamePool)
        },
        Entry(key: "$randomCreditCardMask", summary: "A random masked credit card number (4 digits)") {
            digits(4)
        },
        Entry(key: "$randomBankAccountBic", summary: "A random 8-character BIC code") {
            alphanumeric(8, from: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        },
        Entry(key: "$randomBankAccountIban", summary: "A random IBAN (15-31 characters)") {
            alphanumeric(2, from: "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                + digits(2)
                + alphanumeric(Int.random(in: 11...27), from: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        },
        Entry(key: "$randomTransactionType", summary: "A random transaction type (invoice, payment)") {
            drawRandom(transactionTypePool)
        },
        Entry(key: "$randomCurrencyCode", summary: "A random 3-letter currency code (ISO 4217)") {
            drawRandom(currencyCodePool)
        },
        Entry(key: "$randomCurrencyName", summary: "A random currency name") {
            drawRandom(currencyNamePool)
        },
        Entry(key: "$randomCurrencySymbol", summary: "A random currency symbol") {
            drawRandom(currencySymbolPool)
        },
        Entry(key: "$randomBitcoin", summary: "A random bitcoin address (26-34 characters)") {
            alphanumeric(Int.random(in: 26...34), from: "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        },
    ]

    // MARK: - Business

    private static let business: [Entry] = [
        Entry(key: "$randomCompanyName", summary: "A random company name") {
            Bool.random()
                ? "\(drawRandom(lastNamePool)) - \(drawRandom(lastNamePool))"
                : "\(drawRandom(lastNamePool)) \(drawRandom(companySuffixPool))"
        },
        Entry(key: "$randomCompanySuffix", summary: "A random company suffix (Inc, LLC)") {
            drawRandom(companySuffixPool)
        },
        Entry(key: "$randomBs", summary: "A random phrase of business-speak") {
            "\(drawRandom(bsAdjectivePool)) \(drawRandom(bsBuzzPool)) \(drawRandom(bsNounPool))"
        },
        Entry(key: "$randomBsAdjective", summary: "A random business-speak adjective") {
            drawRandom(bsAdjectivePool)
        },
        Entry(key: "$randomBsBuzz", summary: "A random business-speak buzzword") {
            drawRandom(bsBuzzPool)
        },
        Entry(key: "$randomBsNoun", summary: "A random business-speak noun") {
            drawRandom(bsNounPool)
        },
    ]

    // MARK: - Catchphrases

    private static let catchphrases: [Entry] = [
        Entry(key: "$randomCatchPhrase", summary: "A random catchphrase") {
            "\(drawRandom(catchPhraseAdjectivePool)) \(drawRandom(catchPhraseDescriptorPool)) \(drawRandom(catchPhraseNounPool))"
        },
        Entry(key: "$randomCatchPhraseAdjective", summary: "A random catchphrase adjective") {
            drawRandom(catchPhraseAdjectivePool)
        },
        Entry(key: "$randomCatchPhraseDescriptor", summary: "A random catchphrase descriptor") {
            drawRandom(catchPhraseDescriptorPool)
        },
        Entry(key: "$randomCatchPhraseNoun", summary: "A random catchphrase noun") {
            drawRandom(catchPhraseNounPool)
        },
    ]

    // MARK: - Databases

    private static let databases: [Entry] = [
        Entry(key: "$randomDatabaseColumn", summary: "A random database column name") {
            drawRandom(databaseColumnPool)
        },
        Entry(key: "$randomDatabaseType", summary: "A random database column type") {
            drawRandom(databaseTypePool)
        },
        Entry(key: "$randomDatabaseCollation", summary: "A random database collation") {
            drawRandom(databaseCollationPool)
        },
        Entry(key: "$randomDatabaseEngine", summary: "A random database engine") {
            drawRandom(databaseEnginePool)
        },
    ]

    // MARK: - Dates

    private static let dates: [Entry] = [
        Entry(key: "$randomDateFuture", summary: "A random datetime up to 30 days from now") {
            jsStringValue(Date().addingTimeInterval(Double.random(in: 60...(86_400 * 30))))
        },
        Entry(key: "$randomDatePast", summary: "A random datetime in the last two years") {
            jsStringValue(Date().addingTimeInterval(-Double.random(in: 0...(86_400 * 730))))
        },
        Entry(key: "$randomDateRecent", summary: "A random datetime within the last hour") {
            jsStringValue(Date().addingTimeInterval(-Double.random(in: 0...3_600)))
        },
        Entry(key: "$randomWeekday", summary: "A random weekday name") {
            drawRandom(weekdayPool)
        },
        Entry(key: "$randomMonth", summary: "A random month name") {
            drawRandom(monthPool)
        },
    ]

    // MARK: - Domains, emails, and usernames

    private static let domainsEmailsUsernames: [Entry] = [
        Entry(key: "$randomDomainName", summary: "A random domain name") {
            "\(drawRandom(lastNamePool).lowercased()).\(drawRandom(domainSuffixPool))"
        },
        Entry(key: "$randomDomainSuffix", summary: "A random domain suffix (com, net)") {
            drawRandom(domainSuffixPool)
        },
        Entry(key: "$randomDomainWord", summary: "A random unqualified domain name") {
            drawRandom(lastNamePool).lowercased()
        },
        Entry(key: "$randomEmail", summary: "A random email address") {
            emailString(domainPool: emailDomainPool)
        },
        Entry(key: "$randomExampleEmail", summary: "A random email address on an example domain") {
            emailString(domainPool: exampleDomainPool)
        },
        Entry(key: "$randomUserName", summary: "A random username") {
            let first = drawRandom(firstNamePool)
            let last = drawRandom(lastNamePool)
            switch Int.random(in: 0..<3) {
            case 0: return "\(first).\(last)"
            case 1: return "\(first).\(last)\(digits(Int.random(in: 1...3)))"
            default: return "\(first)\(digits(Int.random(in: 1...3)))"
            }
        },
        Entry(key: "$randomUrl", summary: "A random URL (scheme + domain)") {
            "\(Bool.random() ? "https" : "http")://\(drawRandom(lastNamePool).lowercased()).\(drawRandom(domainSuffixPool))"
        },
    ]

    // MARK: - Files and directories

    private static let filesAndDirectories: [Entry] = [
        Entry(key: "$randomFileName", summary: "A random file name (may include uncommon extensions)") {
            snakeWords(Int.random(in: 2...4)) + "." + drawRandom(uncommonFileExtensionPool)
        },
        Entry(key: "$randomFileType", summary: "A random file type (may be uncommon)") {
            drawRandom(fileTypePool)
        },
        Entry(key: "$randomFileExt", summary: "A random file extension (may be uncommon)") {
            drawRandom(uncommonFileExtensionPool)
        },
        Entry(key: "$randomCommonFileName", summary: "A random file name with a common extension") {
            snakeWords(2) + "." + drawRandom(commonFileExtensionPool)
        },
        Entry(key: "$randomCommonFileType", summary: "A random common file type") {
            drawRandom(fileTypePool)
        },
        Entry(key: "$randomCommonFileExt", summary: "A random common file extension") {
            drawRandom(commonFileExtensionPool)
        },
        Entry(key: "$randomFilePath", summary: "A random file path") {
            "/\(drawRandom(directoryWordPool))/\(snakeWords(2)).\(drawRandom(uncommonFileExtensionPool))"
        },
        Entry(key: "$randomDirectoryPath", summary: "A random directory path") {
            drawRandom(directoryPathPool)
        },
        Entry(key: "$randomMimeType", summary: "A random MIME type") {
            drawRandom(mimeTypePool)
        },
    ]

    // MARK: - Stores

    private static let stores: [Entry] = [
        Entry(key: "$randomPrice", summary: "A random price between 0.00 and 1000.00") {
            String(format: "%.2f", Double.random(in: 0...1_000))
        },
        Entry(key: "$randomProduct", summary: "A random product name") {
            drawRandom(productPool)
        },
        Entry(key: "$randomProductAdjective", summary: "A random product adjective") {
            drawRandom(productAdjectivePool)
        },
        Entry(key: "$randomProductMaterial", summary: "A random product material") {
            drawRandom(productMaterialPool)
        },
        Entry(key: "$randomProductName", summary: "A random product name (adjective + material + product)") {
            "\(drawRandom(productAdjectivePool)) \(drawRandom(productMaterialPool)) \(drawRandom(productPool))"
        },
        Entry(key: "$randomDepartment", summary: "A random commerce category") {
            drawRandom(departmentPool)
        },
    ]

    // MARK: - Grammar

    private static let grammar: [Entry] = [
        Entry(key: "$randomNoun", summary: "A random noun") {
            drawRandom(techNounPool)
        },
        Entry(key: "$randomVerb", summary: "A random verb") {
            drawRandom(techVerbPool)
        },
        Entry(key: "$randomIngverb", summary: "A random -ing verb") {
            drawRandom(techIngverbPool)
        },
        Entry(key: "$randomAdjective", summary: "A random technical adjective") {
            drawRandom(techAdjectivePool)
        },
        Entry(key: "$randomWord", summary: "A random word (any grammar)") {
            drawRandom(techNounPool + techVerbPool + techAdjectivePool)
        },
        Entry(key: "$randomWords", summary: "Some random words") {
            (0..<Int.random(in: 3...5)).map { _ in drawRandom(generalWordPool).capitalized }.joined(separator: " ")
        },
        Entry(key: "$randomPhrase", summary: "A random made-up phrase") {
            let verb = drawRandom(techVerbPool)
            let noun = drawRandom(techNounPool)
            let ing = drawRandom(techIngverbPool)
            let adjective = drawRandom(techAdjectivePool)
            let otherNoun = drawRandom(techNounPool)
            return "You can't \(verb) the \(noun) without \(ing) the \(adjective) \(otherNoun)!"
        },
    ]

    // MARK: - Lorem ipsum

    private static let loremIpsum: [Entry] = [
        Entry(key: "$randomLoremWord", summary: "A random word of lorem ipsum text") {
            drawRandom(loremWordPool)
        },
        Entry(key: "$randomLoremWords", summary: "Some random lorem ipsum words") {
            (0..<Int.random(in: 3...4)).map { _ in drawRandom(loremWordPool) }.joined(separator: " ")
        },
        Entry(key: "$randomLoremSentence", summary: "A random sentence of lorem ipsum text") {
            loremSentence()
        },
        Entry(key: "$randomLoremSentences", summary: "2-6 random lorem ipsum sentences") {
            loremSentences(Int.random(in: 2...6))
        },
        Entry(key: "$randomLoremParagraph", summary: "A random paragraph of lorem ipsum text") {
            loremSentences(Int.random(in: 4...6))
        },
        Entry(key: "$randomLoremParagraphs", summary: "3 random lorem ipsum paragraphs") {
            (0..<3).map { _ in loremSentences(Int.random(in: 4...6)) }.joined(separator: "\n\n")
        },
        Entry(key: "$randomLoremText", summary: "A random amount of lorem ipsum text") {
            loremSentences(Int.random(in: 4...8))
        },
        Entry(key: "$randomLoremSlug", summary: "A random lorem ipsum URL slug") {
            (0..<Int.random(in: 3...5)).map { _ in drawRandom(loremWordPool) }.joined(separator: "-")
        },
        Entry(key: "$randomLoremLines", summary: "1-5 random lines of lorem ipsum") {
            (0..<Int.random(in: 1...5)).map { _ in loremSentence() }.joined(separator: "\n")
        },
    ]

    // MARK: - Generators (shared helpers)

    /// Pools are non-empty constants; drawRandom is only their shape.
    private static func drawRandom(_ pool: [String]) -> String {
        pool.randomElement() ?? ""
    }

    private static func digits(_ count: Int) -> String {
        (0..<count).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    private static func hexChars(_ count: Int) -> String {
        alphanumeric(count, from: "0123456789abcdef")
    }

    private static func alphanumeric(_ count: Int, from pool: String) -> String {
        let characters = Array(pool)
        return String((0..<count).map { _ in characters.randomElement() ?? "a" })
    }

    private static func coordinate(_ range: ClosedRange<Double>) -> String {
        String(format: "%.4f", Double.random(in: range))
    }

    /// An email in the Faker shape: a mixed-case `first(.last)` handle, an
    /// optional trailing digit run, and a provider domain.
    private static func emailString(domainPool: [String]) -> String {
        let first = drawRandom(firstNamePool)
        let last = drawRandom(lastNamePool)
        let handle = Bool.random() ? "\(first)\(digits(Int.random(in: 1...3)))" : "\(first).\(last)\(digits(Int.random(in: 1...3)))"
        return "\(handle)@\(drawRandom(domainPool))"
    }

    /// Lowercase snake_case words (file names, paths).
    private static func snakeWords(_ count: Int) -> String {
        (0..<count).map { _ in drawRandom(generalWordPool).lowercased() }.joined(separator: "_")
    }

    /// JS `Date`-style datetime string: `EEE MMM d yyyy HH:mm:ss GMT±hhmm`
    /// (JavaScript's Data toString shape, local time). Fresh formatter per
    /// call, like the ISO builder above - the generators may run on
    /// concurrent resolver threads, and `DateFormatter` is not thread-safe.
    private static func jsStringValue(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d yyyy HH:mm:ss 'GMT'ZZZ"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// One capitalized, period-terminated lorem sentence.
    private static func loremSentence() -> String {
        var sentence = (0..<Int.random(in: 8...14)).map { _ in drawRandom(loremWordPool) }
            .joined(separator: " ")
        sentence = sentence.prefix(1).capitalized + sentence.dropFirst()
        return sentence + "."
    }

    private static func loremSentences(_ count: Int) -> String {
        (0..<count).map { _ in loremSentence() }.joined(separator: " ")
    }

    // MARK: - Data pools

    private static let firstNamePool = [
        "Connor", "Megane", "Chandler", "Ethan", "Sylvan", "Connie", "Jonathon",
        "Pablo", "Ruthe", "Iva", "Talon", "Quinten", "Casey", "Jarrell",
        "Lottie", "Alia", "Gracie", "Armando", "Trevor", "Anais", "Tristin",
        "Jakob", "Ada", "Grace", "Alan", "Barbara", "Radia", "Margaret",
        "Frances", "Anita", "Sophie", "Rosa", "Hedy", "Claude", "Katherine",
        "Mary", "Kendrick", "Nina", "Marvin", "Leffler",
    ]
    private static let lastNamePool = [
        "Runolfsdottir", "Fay", "Kunze", "Schaden", "Schneider", "Willms",
        "Kassulke", "Grady", "Gutkowski", "Smitham", "Kerluke", "Kovacek",
        "Lovelace", "Turing", "Hopper", "Dijkstra", "Liskov", "Knuth",
        "Perlman", "Hamilton", "Ritchie", "Thompson", "Torvalds", "Wilson",
        "Gosling", "Minsky", "Lamarr", "Shannon", "Backus", "Keller", "Harvey",
        "Wilmer", "Kuhic", "Spinka", "Korbin",
    ]
    private static let namePrefixPool = [
        "Mr.", "Mrs.", "Ms.", "Miss", "Dr.", "Prof.", "Hon.", "Rev.",
    ]
    private static let nameSuffixPool = [
        "I", "II", "III", "IV", "V", "MD", "DDS", "PhD", "DMD", "Esq.",
    ]
    private static let jobAreaPool = [
        "Mobility", "Intranet", "Configuration", "Research", "Integration",
        "Data", "Creative", "Division", "Functionality", "Usability",
        "Communications", "Marketing", "Paradigm", "Quality", "Metrics",
        "Assurance", "Security", "Tactics", "Program", "Design",
    ]
    private static let jobDescriptorPool = [
        "Forward", "Corporate", "Senior", "National", "Regional", "Principal",
        "Global", "Customer", "Central", "Investor", "Future", "Dynamic",
        "Internal", "Human", "Direct", "Product", "International", "Chief",
    ]
    private static let jobTypePool = [
        "Supervisor", "Manager", "Coordinator", "Executive", "Associate",
        "Producer", "Representative", "Assistant", "Officer", "Architect",
        "Analyst", "Consultant", "Engineer", "Specialist", "Developer",
        "Agent", "Technician", "Planner", "Director", "Liaison",
    ]
    private static let streetSuffixPool = [
        "Island", "Street", "Springs", "Manor", "Garden", "Hill", "Parkway",
        "Crossing", "Way", "Square", "Trail", "Lodge", "Court", "Circle",
        "Vista", "Ramp", "Grove", "Terrace", "Cove", "Mews", "Causeway",
        "Boulevard", "Alley", "Fields", "Center", "Highway", "View", "Shore",
        "Track", "Union", "Station", "Junction", "Path", "Bridge", "Ford",
        "Summit", "Village", "Forge", "Tunnel", "Gateway", "Expressway",
        "Route", "Underpass", "Stream", "Turnpike", "Course", "Brook",
    ]
    private static let cityPool = [
        "Spinkahaven", "Korbinburgh", "Lefflerport", "Zurich", "Berlin",
        "Amsterdam", "Kyoto", "Lisbon", "Toronto", "Denver", "Oslo", "Prague",
        "Vienna", "Barcelona", "Dublin", "Helsinki", "Seoul", "Singapore",
        "Austin", "Montreal", "Copenhagen",
    ]
    private static let countryPool = [
        "Switzerland", "Germany", "Netherlands", "Japan", "Portugal",
        "Canada", "United States", "Norway", "Czech Republic", "Austria",
        "Spain", "Ireland", "Finland", "South Korea", "Singapore",
        "Australia", "Kazakhstan", "Lao People's Democratic Republic",
    ]
    private static let countryCodePool = [
        "CV", "MD", "TD", "CH", "US", "DE", "NL", "JP", "PT", "CA", "NO",
        "AT", "ES", "IE", "FI", "KR", "SG", "AU", "GB", "FR", "SE", "IT",
    ]
    private static let bankAccountNamePool = [
        "Home Loan Account", "Checking Account", "Savings Account",
        "Auto Loan Account", "Personal Loan Account", "Credit Card Account",
        "Money Market Account", "Investment Account", "Mortgage Account",
    ]
    private static let transactionTypePool = [
        "invoice", "payment", "deposit", "withdrawal", "transfer", "refund",
    ]
    private static let currencyCodePool = [
        "USD", "EUR", "GBP", "JPY", "CNY", "CHF", "CAD", "AUD", "SEK",
        "KRW", "CDF", "ZMK", "GNF", "INR", "BRL", "DKK", "ILS", "NOK",
        "PLN", "RUB", "TRY",
    ]
    private static let currencyNamePool = [
        "United States Dollar", "Euro", "Pound Sterling", "Swiss Franc",
        "Japanese Yen", "Australian Dollar", "Canadian Dollar",
        "Chinese Yuan", "Cordoba Oro", "CFP Franc", "Brazilian Real",
        "Indian Rupee", "Danish Krone", "Israeli New Sheqel",
        "South Korean Won", "Norwegian Krone", "Polish Zloty",
        "Russian Ruble", "Swedish Krona", "Turkish Lira",
    ]
    private static let currencySymbolPool = ["$", "£", "¥", "€", "₩", "₽", "₹"]
    private static let companySuffixPool = [
        "Inc", "LLC", "Group", "Ltd", "and Sons", "PLC", "AG", "GmbH", "Co",
        "Industries", "Corporation",
    ]
    private static let bsAdjectivePool = [
        "viral", "24/7", "24/365", "back-end", "best-of-breed",
        "clicks-and-mortar", "B2B", "B2C", "e-business", "open-source",
        "out-of-the-box", "plug-and-play", "real-time", "sticky", "turn-key",
        "user-centric", "cross-media", "wireless", "vertical", "front-end",
        "one-to-one", "synergistic", "bleeding-edge", "web-enabled",
        "intuitive", "killer", "value-added", "world-class", "dynamic",
        "cutting-edge", "six-sigma", "customizable", "rich", "proactive",
        "leading-edge", "granular", "next-generation", "end-to-end",
        "magnetic", "holistic", "impactful", "extensible", "robust",
        "seamless", "frictionless", "visionary", "innovative", "strategic",
        "enterprise", "transparent", "mission-critical", "efficient",
        "ubiquitous",
    ]
    private static let bsBuzzPool = [
        "repurpose", "harness", "disintermediate", "syndicate", "matrix",
        "transition", "envisioneer", "evolve", "whiteboard", "reorient",
        "strategize", "scale", "recontextualize", "maximize", "deploy",
        "engineer", "incubate", "iterate", "redefine", "aggregate",
        "innovate", "empower", "mesh", "facilitate", "transform", "expedite",
        "engage", "drive", "orchestrate", "grow", "brand", "streamline",
        "collaborate", "generate", "leverage", "incentivize", "exploit",
        "optimize", "integrate", "implement", "synthesize", "monetize",
        "unleash", "embrace", "extend", "dominate", "visualize", "deliver",
        "productize", "revolutionize", "benchmark", "target",
    ]
    private static let bsNounPool = [
        "e-services", "markets", "interfaces", "users", "leadership",
        "web-readiness", "action-items", "channels", "relationships",
        "e-business", "infrastructures", "content", "convergence", "models",
        "platforms", "vortals", "networks", "e-commerce", "architectures",
        "synergies", "connectivity", "technologies", "schemas",
        "applications", "bandwidth", "partnerships", "metrics",
        "deliverables", "mindshare", "supply-chains", "e-markets",
        "initiatives", "niches", "functionalities", "methodologies",
        "verticals", "eyeballs", "communities", "ROI", "web services",
        "visions", "features", "blockchains", "portals", "systems", "graphs",
        "products", "web users", "e-tailers", "solutions", "schemas",
    ]
    private static let catchPhraseAdjectivePool = [
        "Self-enabling", "Business-focused", "Down-sized", "Advanced",
        "Inverse", "Customizable", "Right-sized", "Realigned",
        "Ameliorated", "Optional", "Compatible", "Progressive",
        "Switchable", "Open-source", "Multi-channelled", "Profound",
        "Front-line", "Expanded", "Diverse", "Cross-group", "Exclusive",
        "User-friendly", "Extended", "Future-proofed", "Up-sized",
        "Horizontal", "Cross-platform", "Monitored", "Persevering",
        "Quality-focused", "Pre-emptive", "Multi-tiered",
        "Vision-oriented", "Innovative", "Secured", "Devolved",
        "Front-enabled", "Fully-configurable", "Interactive", "Managed",
        "Cross-functional", "Balanced", "Enhanced", "Integrated",
        "Team-oriented", "Persistent", "Universal", "Robust", "Reactive",
        "Organic", "Sharable", "Self-cultivating", "Multi-lateral",
        "Digitized", "De-engineered", "Stand-alone", "Fully-tested",
        "Polarized", "Decentralized", "Upgradable", "Horizon-oriented",
        "Focused", "Coherent", "Synergized", "Networked", "Validated",
        "Objective", "Effective", "Streamlined", "Ergonomic",
        "Contingency-oriented",
    ]
    private static let catchPhraseDescriptorPool = [
        "bandwidth-monitored", "needs-based", "homogeneous", "asymmetric",
        "fault-tolerant", "multi-layered", "well-modulated", "configurable",
        "client-driven", "holistic", "reduced", "down-sized",
        "decentralized", "team-oriented", "matrix", "stand-alone",
        "mission-critical", "full-range", "foreground", "value-added",
        "line-oriented", "human-resource", "installation", "national",
        "systematic", "optimizing", "multi-channelled", "centralized",
        "didactic", "open-architected", "intangible", "regional",
        "user-facing", "modular", "third-generation", "extended",
        "integrated", "right-sized", "local", "zero-defect", "interactive",
        "user-centric", "zero-tolerance", "eco-centric", "explicit",
        "next-generation", "digitized", "bottom-line", "client-server",
    ]
    private static let catchPhraseNounPool = [
        "secured line", "superstructure", "installation", "capability",
        "projection", "objective", "open architecture",
        "artificial intelligence", "data-warehouse", "budgetary management",
        "contingency", "pricing structure", "intranet", "forecast",
        "success", "graphical user interface", "benchmark", "challenge",
        "info-mediaries", "standardization", "protocol", "algorithm",
        "attitude", "coordinates", "service-desk", "architecture", "policy",
        "hub", "hierarchy", "core",
    ]
    private static let databaseColumnPool = [
        "updatedAt", "createdAt", "id", "name", "token", "password",
        "group", "email", "status", "user", "userId", "type", "description",
        "title", "deletedAt", "code", "value", "key", "category", "level",
    ]
    private static let databaseTypePool = [
        "tinyint", "smallint", "mediumint", "int", "bigint", "decimal",
        "float", "double", "text", "varchar", "char", "datetime",
        "timestamp", "date", "blob", "json", "enum", "boolean",
    ]
    private static let databaseCollationPool = [
        "cp1250_bin", "cp1250_general_ci", "utf8_general_ci",
        "utf8_unicode_ci", "utf8mb4_unicode_ci", "utf8mb4_bin",
        "latin1_swedish_ci", "binary",
    ]
    private static let databaseEnginePool = [
        "MyISAM", "InnoDB", "Memory", "Archive", "CSV", "Blackhole",
        "Falcon", "MRG_MyISAM",
    ]
    private static let weekdayPool = [
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
        "Sunday",
    ]
    private static let monthPool = [
        "January", "February", "March", "April", "May", "June", "July",
        "August", "September", "October", "November", "December",
    ]
    private static let domainSuffixPool = [
        "com", "net", "org", "io", "name", "biz", "info",
    ]
    private static let emailDomainPool = [
        "gmail.com", "hotmail.com", "outlook.com", "yahoo.com", "aol.com",
        "icloud.com",
    ]
    private static let exampleDomainPool = [
        "example.com", "example.net", "example.org",
    ]
    private static let fileTypePool = [
        "model", "application", "video", "audio", "text", "image", "font",
        "message", "multipart", "example",
    ]
    private static let uncommonFileExtensionPool = [
        "war", "book", "fsc", "gdoc", "ipynb", "xcf", "dcm", "iso", "zep",
        "tsd", "prc", "gpkg", "ase", "nar", "numbers", "avif", "epub",
        "rmp", "fh9", "dwg", "cpio",
    ]
    private static let commonFileExtensionPool = [
        "m2v", "wav", "png", "jpg", "jpeg", "gif", "pdf", "svg", "mp3",
        "mp4", "mpg", "txt", "html", "zip", "tgz", "mov", "json", "yaml",
        "xml", "csv",
    ]
    private static let directoryWordPool = ["home", "root", "usr", "etc", "var", "tmp", "opt"]
    private static let directoryPathPool = [
        "/usr/bin", "/root", "/usr/local/bin", "/etc", "/var/log", "/home",
        "/opt", "/bin", "/usr/share", "/var/tmp",
    ]
    private static let mimeTypePool = [
        "text/html", "text/plain", "application/json", "application/pdf",
        "image/png", "image/jpeg", "audio/mpeg", "video/mp4",
        "application/octet-stream", "application/xml", "text/csv",
        "audio/vnd.vmx.cvsd", "application/vnd.api+json", "video/quicktime",
        "application/xhtml+xml", "image/svg+xml",
    ]
    private static let productPool = [
        "Towels", "Pizza", "Pants", "Keyboard", "Cheese", "Computer",
        "Bicycle", "Gloves", "Soap", "Table", "Chicken", "Hat", "Shirt",
        "Car", "Fish", "Tuna", "Bacon", "Salad", "Ball", "Chair", "Mouse",
        "Coat", "Parser", "Soap", "Licence",
    ]
    private static let productAdjectivePool = [
        "Unbranded", "Incredible", "Tasty", "Refined", "Small", "Generic",
        "Awesome", "Practical", "Sleek", "Intelligent", "Handmade",
        "Gorgeous", "Rustic", "Fantastic", "Luxurious", "Ergonomic",
    ]
    private static let productMaterialPool = [
        "Steel", "Plastic", "Frozen", "Cotton", "Rubber", "Bronze",
        "Wooden", "Concrete", "Soft", "Fresh", "Granite", "Leather",
        "Metal", "Silk", "Paper", "Linen",
    ]
    private static let departmentPool = [
        "Tools", "Movies", "Electronics", "Clothing", "Computers", "Kids",
        "Beauty", "Sports", "Home", "Grocery", "Health", "Automotive",
        "Baby", "Books", "Toys", "Outdoors", "Shoes", "Music", "Industrial",
        "Garden", "Jewelry", "Games",
    ]
    private static let techNounPool = [
        "matrix", "bus", "bandwidth", "protocol", "array", "sensor",
        "capacitor", "system", "card", "feed", "frame", "hard drive",
        "microchip", "port", "program", "pixel", "transmitter", "alarm",
        "input", "monitor", "circuit", "interface", "driver", "panel",
        "application", "firewall", "router",
    ]
    private static let techVerbPool = [
        "parse", "quantify", "navigate", "calculate", "copy", "index",
        "generate", "synthesize", "compress", "reboot", "transmit",
        "archive", "connect", "hack", "override", "back up", "multiplex",
        "program", "input",
    ]
    private static let techIngverbPool = [
        "synthesizing", "navigating", "backing up", "connecting", "hacking",
        "transmitting", "copying", "parsing", "programming", "indexing",
        "quantifying", "compressing", "calculating", "generating",
        "overriding", "archiving", "rebooting", "multiplexing",
    ]
    private static let techAdjectivePool = [
        "auxiliary", "multi-byte", "back-end", "open-source", "virtual",
        "cross-platform", "primary", "wireless", "neural", "digital",
        "haptic", "solid state", "optical", "1080p", "bluetooth", "mobile",
        "mobile application", "optical sensor",
    ]
    private static let generalWordPool = [
        "Grocery", "Corporate", "Samoa", "sticky", "Snow", "copying",
        "Ghana", "Quality", "Christmas", "Island", "Spring", "Infrastructure",
        "withdrawal", "infrastructures", "IB", "Rustic", "Rubber", "Cet", "Toilet",
        "Frozen", "Deluxe", "Wooden", "small", "cinerea", "belgium",
    ]
    private static let abbreviationPool = [
        "SQL", "PCI", "JSON", "HTTP", "XML", "API", "TCP", "UDP", "DNS",
        "SSL", "TLS", "CSV", "PHP", "CSS", "HTML", "CLI", "CPU", "GPU",
        "RAM", "USB", "LAN", "WAN", "VPN", "PDF", "AWS", "CDN", "REST",
        "SOAP", "SSH", "IoT",
    ]
    private static let localePool = [
        "ny", "sr", "si", "en", "de", "fr", "es", "it", "pt", "ru", "ja",
        "zh", "ko", "ar", "hi", "sv", "da", "fi", "nl", "pl", "tr", "cs",
        "el", "he", "th", "vi", "id", "ms", "no", "hu", "ro", "uk",
    ]
    private static let userAgentPool = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:121.0) Gecko/20100101 Firefox/121.0",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120.0.0.0",
        "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/119.0",
    ]
    private static let colorNamePool = [
        "blue", "red", "green", "yellow", "magenta", "cyan", "orange",
        "purple", "teal", "pink", "brown", "black", "white", "grey",
        "gray", "navy", "lime", "fuchsia", "maroon", "olive", "aqua",
        "silver", "gold", "ivory", "coral", "salmon", "khaki", "plum",
        "orchid", "crimson", "indigo", "violet", "beige", "turquoise",
        "lavender", "chartreuse",
    ]
    private static let loremWordPool = [
        "lorem", "ipsum", "dolor", "sit", "amet", "consectetur",
        "adipiscing", "elit", "sed", "eiusmod", "tempor", "incididunt",
        "labore", "dolore", "magna", "aliqua", "enim", "minim", "veniam",
        "quis", "nostrud", "exercitation", "ullamco", "laboris", "nisi",
        "aliquip", "commodo", "consequat", "duis", "aute", "velit", "esse",
        "cillum", "fugiat", "nulla", "pariatur", "excepteur", "sint",
        "occaecat", "cupidatat", "non", "proident", "sunt", "culpa",
        "qui", "officia", "deserunt", "mollit", "anim", "id", "est",
        "laborum", "vel", "repellat", "nobis", "eos", "aperiam",
        "accusamus", "beatae", "molestiae", "quod", "iusto", "odio",
        "repudiandae", "iste", "fugit", "tenetur", "natus", "quos",
        "aspernatur", "vitae", "doloribus", "atque", "voluptatem",
        "ab", "aliquid", "iste", "quo", "dignissimos", "recusandae",
        "voluptates", "impedit", "asperiores", "exercitationem",
    ]
}
