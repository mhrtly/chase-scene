import Foundation

struct Credit: Codable, Equatable {
    let role: String
    let name: String
}

struct CreditDeck: Equatable {
    let task: String
    let credits: [Credit]
}

enum Credits {
    static func generate(task: String) -> CreditDeck {
        let topic = task.lowercased()
        let rows: [(String, String)]
        if contains(topic, ["window", "minimiz", "tidy desktop"]) {
            rows = [("Director of downsizing", "Minnie Mize"), ("Window disappearance", "Wanda Way"),
                    ("Pane relief", "Les Windows"), ("Desktop clearance", "Clara Space"),
                    ("Keeping a low profile", "Ned Underwood"), ("Restoration department", "Max E. Mize")]
        } else if contains(topic, ["sheet", "spreadsheet", "excel", "csv", "formula", "budget"]) {
            rows = [("Cell block supervisor", "Celia Formula"), ("Keeping things in line", "Colin Rows"),
                    ("Division of division", "Dee Nominator"), ("Missing figures", "Anita Number"),
                    ("Making it all add up", "Adam Up"), ("Balance of power", "Bill Ledger")]
        } else if contains(topic, ["email", "mail", "inbox", "outlook", "gmail"]) {
            rows = [("Director of correspondence", "Reed Receipt"), ("Unsolicited appearances", "Sam Spamm"),
                    ("Reply-all containment", "Al Reply"), ("Attachment issues", "Anita File"),
                    ("Keeping it brief", "Shirley Short"), ("Final delivery", "C. C. Sender")]
        } else if contains(topic, ["calendar", "meeting", "schedule", "appointment"]) {
            rows = [("Date supervision", "Daisy Date"), ("Head of looking busy", "Warren Meeting"),
                    ("A minute of your time", "Justin Time"), ("Conflict resolution", "Claire Schedule"),
                    ("Future appearances", "Manny Ana"), ("Running slightly late", "Etta Morrow")]
        } else if contains(topic, ["flight", "travel", "hotel", "trip", "booking"]) {
            rows = [("Going places", "Miles Away"), ("Baggage handling", "Carrie Onn"),
                    ("Departure supervision", "Wanda Roam"), ("Boarding arrangements", "Al Aboard"),
                    ("Accommodating everyone", "Anita Room"), ("Unscheduled stops", "Dee Tour")]
        } else if contains(topic, ["document", "writing", "report", "word", "copy", "edit"]) {
            rows = [("Page-turning supervision", "Paige Turner"), ("Head of second thoughts", "Ed Itagain"),
                    ("Spelling things out", "Ty Po"), ("Sentence reduction", "Les Words"),
                    ("Punctuation patrol", "Cole N. Stop"), ("The last word", "Finn Ish")]
        } else if contains(topic, ["legal", "contract", "agreement"]) {
            rows = [("Legal advice", "Dewey, Cheatham and Howe"), ("Clause for concern", "Clara Clause"),
                    ("Fine print inspection", "Reed Small"), ("Head of making a case", "Sue Pernickety"),
                    ("Terms of endearment", "Al L. Rights"), ("Last-minute objections", "Justin Case")]
        } else if contains(topic, ["font", "credit", "typograph"]) {
            rows = [("Head of character development", "Al Fabet"), ("Director of fuzzy logic", "Will B. Blurry"),
                    ("Spacing supervision", "Kerning Sanders"), ("Broadcast interference", "Anita Antenna"),
                    ("Upward mobility", "Rollo Credits"), ("The final word", "Finn Allee")]
        } else if contains(topic, ["code", "bug", "build", "test", "github", "app"]) {
            rows = [("Chief bug wrangler", "Anita Patch"), ("Unexpected exceptions", "Justin Case"),
                    ("Passing the buck", "Bill D. Failed"), ("Head of going in circles", "Lou P. Again"),
                    ("Version confusion", "Marge Conflict"), ("Final quality assurance", "Itza Feature")]
        } else if contains(topic, ["file", "folder", "organis", "organiz", "download"]) {
            rows = [("Filing complaints", "Al Fabet"), ("Folder disappearance", "Wanda File"),
                    ("Duplicate appearances", "E. C. Copy"), ("Space management", "Clara Disk"),
                    ("Loose ends", "Anita Folder"), ("Finding everything", "Seymour Files")]
        } else if contains(topic, ["browser", "web", "search", "chrome", "tab"]) {
            rows = [("Head of tab proliferation", "Tabitha Close"), ("Search party leader", "Seymour Results"),
                    ("Click choreography", "Cliff Hanger"), ("Page loading", "Wade A. Minute"),
                    ("Cookie negotiations", "Chip Pending"), ("Back-button supervision", "Dee Tour")]
        } else {
            rows = [("Pointer choreography", "Cliff Click"), ("Mouse stunt double", "Minnie Moves"),
                    ("Head of unnecessary scrolling", "Skip A. Head"), ("Keeping everyone waiting", "Wade A. Minute"),
                    ("Department of reassurance", "Justin Case"), ("Finishing touches", "Al Mostdone")]
        }
        return CreditDeck(task: task, credits: rows.map { Credit(role: $0.0, name: $0.1) })
    }

    private static func contains(_ topic: String, _ words: [String]) -> Bool {
        // Match at word starts: "edit" inside "credits" is not a document-editing task.
        words.contains { topic.range(of: "(?<![a-z])" + NSRegularExpression.escapedPattern(for: $0),
            options: .regularExpression) != nil }
    }

    static func parse(_ request: [String: Any]) throws -> CreditDeck? {
        guard request["task"] != nil || request["credits"] != nil else { return nil }
        let task = try text(request["task"] ?? "Desktop control", key: "task", limit: 160)
        guard let value = request["credits"] else { return generate(task: task) }
        guard let rows = value as? [[String: Any]], (1...12).contains(rows.count) else {
            throw ControlError.invalid("credits must contain between 1 and 12 role/name pairs.")
        }
        return CreditDeck(task: task, credits: try rows.map {
            Credit(role: try text($0["role"], key: "role", limit: 64),
                   name: try text($0["name"], key: "name", limit: 64))
        })
    }

    private static func text(_ value: Any?, key: String, limit: Int) throws -> String {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespaces).isEmpty,
              value.count <= limit, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ControlError.invalid("\(key) must be a single line of 1–\(limit) characters.")
        }
        return value
    }

    // Only a topic label is retained; no prompts, script arguments, URLs or transcripts are saved.
    static func hookTopic(name: String, input: [String: Any]) -> String {
        let hint = name + " " + ["code", "url", "action", "title", "task"].compactMap { input[$0] as? String }.joined(separator: " ")
        let lower = String(hint.prefix(32768)).lowercased()
        let groups: [(String, [String])] = [
            ("Window management", ["minimiz", "window", "finder"]),
            ("Spreadsheets", ["excel", "spreadsheet", "csv", "formula"]),
            ("Email", ["gmail", "outlook", "inbox", "email"]),
            ("Calendar scheduling", ["calendar", "schedule", "appointment"]),
            ("Travel planning", ["flight", "hotel", "travel"]),
            ("Document editing", ["document", "word", "pages", "copy edit"]),
            ("App development", ["github", "debug", "code editor"]),
            ("File organisation", ["folder", "files", "download"]),
            ("Web browsing", ["browser", "chrome", "playwright", "gettab", "createbrowsertab"])
        ]
        return groups.first { contains(lower, $0.1) }?.0 ?? "Desktop control"
    }
}
