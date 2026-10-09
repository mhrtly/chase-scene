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

    /// Optional AI-authored metadata embedded in a JS desktop action: no extra tool call.
    /// Read only explicit comments near the start, never arbitrary JSON in scripts or transcripts.
    static func hookCredits(input: [String: Any]) -> CreditDeck? {
        guard let code = input["code"] as? String else { return nil }
        for line in code.prefix(8192).split(separator: "\n").prefix(8) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefix = "// chase-credits: "
            guard trimmed.hasPrefix(prefix) else { continue }
            let json = String(trimmed.dropFirst(prefix.count))
            guard json.utf8.count <= 4096,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
            return try? parse(object)
        }
        return nil
    }

    static func fresh(task: String, index: Int) -> Credit {
        let base = generate(task: task).credits
        if index < base.count { return base[index] }
        let extra: [String]
        let nouns: [String]
        switch base.first?.name {
        case "Minnie Mize":
            extra = ["Otto Arrange", "Rita Size", "Hal F. Screen", "Winnie Dow", "Dee Clutter", "Moe V. Over", "Lefty Wright", "Clara View", "Minnie Malist", "Sid E. Byside", "Curt N. Call", "Pane N. Suffering"]
            nouns = ["Space", "Room", "Corner", "Pane", "View", "Window", "Layout", "Margin", "Desk", "Screen"]
        case "Celia Formula":
            extra = ["Tess T. Cell", "Sum Won", "Val U. Added", "Row Z. Tinted", "Cal Q. Later", "Connie Stant", "Norm Alize", "Countess Rows", "Penny Decimal", "Andy Range", "Faye Lookup", "Phil Down"]
            nouns = ["Cell", "Formula", "Column", "Row", "Total", "Number", "Sum", "Table", "Chart", "Balance"]
        case "Reed Receipt":
            extra = ["Phil T. Inbox", "Dee Livery", "Faye Forward", "Anita Reply", "Sue B. Ject", "Maude E. Rator", "Al L. Mail", "Carrie Attachments", "Reed A. Gain", "Nora Spam", "Pete E. Forward", "Manny Messages"]
            nouns = ["Reply", "Stamp", "Message", "Subject", "Attachment", "Inbox", "Draft", "Address", "Filter", "Receipt"]
        case "Daisy Date":
            extra = ["Wanda Slot", "Cal En. Dar", "May B. Available", "Hal F. Hour", "Phil A. Slot", "Anita Break", "Drew Schedule", "Sue N. Enough", "Manny Minutes", "Celia Later", "Justin Tomorrow", "Al L. Day"]
            nouns = ["Date", "Minute", "Slot", "Break", "Meeting", "Agenda", "Reminder", "Hour", "Day", "Plan"]
        case "Miles Away":
            extra = ["Rhoda Trip", "Wanda Holiday", "May B. Delayed", "Connie Connection", "Gail Force", "Drew Itinerary", "Faye R. Away", "Jet T. Lag", "Al L. Inclusive", "Ray Turnticket", "Anita Upgrade", "Wade A. Gate"]
            nouns = ["Seat", "Room", "Ticket", "Gate", "Map", "Flight", "Route", "Stop", "Trip", "Booking"]
        case "Paige Turner":
            extra = ["Dot Comma", "Reed Wright", "Al L. Write", "Drew A. Blank", "Anita Rewrite", "Faye S. Value", "Wanda Paragraph", "Hugh Edit", "Manny Words", "Phil A. Page", "Tex T. Wrap", "Nora Typo"]
            nouns = ["Page", "Word", "Paragraph", "Sentence", "Comma", "Draft", "Heading", "Title", "Chapter", "Edit"]
        case "Dewey, Cheatham and Howe":
            extra = ["Lou Pole", "Sue Yu", "Al L. Egedly", "Clara Fication", "Wanda Clause", "Nora Liability", "Hugh Objection", "Reed A. Contract", "Phil E. Motion", "Connie Sideration", "Jury Stillout", "Finn E. Print"]
            nouns = ["Clause", "Case", "Term", "Copy", "Signature", "Objection", "Agreement", "Witness", "Right", "Point"]
        case "Al Fabet" where task.lowercased().contains("file") || task.lowercased().contains("folder"):
            extra = ["Dirk T. Ory", "Faye L. Extension", "Pat H. Finder", "Drew A. Folder", "Connie Tents", "Reed Me", "Phil E. Away", "Carrie Copies", "Nora Duplicate", "Clara Path", "Sue B. Folder", "Manny Files"]
            nouns = ["File", "Folder", "Name", "Copy", "Disk", "Path", "Directory", "Space", "Archive", "Label"]
        case "Al Fabet":
            extra = ["Hugh Contrast", "Whitey Bright", "Anita Shadow", "B. O. Ld", "Art E. Fact", "Gloria Glow", "Faye D. In", "Shady Letters", "Clara Letter", "Nora Blur", "Rita Font", "Will B. Readable"]
            nouns = ["Shadow", "Letter", "Font", "Line", "Credit", "Glow", "Outline", "Pixel", "Character", "Contrast"]
        case "Anita Patch":
            extra = ["Ada Commit", "Tess T. Suite", "Cody Review", "Al Gorithm", "Dee Bugger", "Hugh Manerror", "Polly Morph", "Gus Decompile", "Cache McMoney", "Pat Chwork", "Connie Current", "Dee Pendency"]
            nouns = ["Patch", "Test", "Commit", "Build", "Branch", "Fix", "Review", "Function", "Check", "Release"]
        case "Tabitha Close":
            extra = ["Link N. Park", "Page E. Down", "Clara Cache", "Wanda Search", "Nora Popup", "Phil T. Query", "Ray Fresh", "Hugh R. L.", "Dee Fault", "Will B. Loaded", "Anita Link", "Ida Bookmark"]
            nouns = ["Tab", "Link", "Page", "Result", "Query", "Bookmark", "Browser", "Cache", "Cookie", "Search"]
        default:
            extra = ["Manny Steps", "Dee Tails", "Clara Progress", "Nora Pause", "Phil A. Gap", "Anita Update", "Hugh Improvement", "Wanda Finish", "Lou K. Again", "Finn Allee", "Moe Mentum", "Will B. Done"]
            nouns = ["Step", "Update", "Result", "Moment", "Clue", "Hand", "Look", "Plan", "Check", "Break"]
        }
        let offset = index - base.count
        let name: String
        if offset < extra.count { name = extra[offset] }
        else {
            // Gap fillers are local wordplay, not claims that another AI is generating text.
            let n = offset - extra.count
            let stems = ["Anita", "Wanda", "Seymour", "Ida"]
            let qualifiers = ["", "More ", "Little ", "Better ", "New ", "Another ", "Proper ", "Final "]
            name = "\(stems[(n / nouns.count) % stems.count]) \(qualifiers[(n / (nouns.count * stems.count)) % qualifiers.count])\(nouns[n % nouns.count])"
        }
        return Credit(role: base[offset % base.count].role, name: name)
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

/// A bounded stream: new workflow updates replace only unused rows. Visible rows keep moving.
final class CreditStream {
    private(set) var task = "Desktop control"
    private var lastDeck: CreditDeck?
    private var pending: [Credit] = []
    private var seen: Set<String> = []
    private var history: [String] = []
    private var fallbackIndex = 0
    private(set) var emitted = 0

    func update(_ deck: CreditDeck) {
        guard deck != lastDeck else { return }
        if deck.task != task { fallbackIndex = 0 }
        task = deck.task
        lastDeck = deck
        pending = deck.credits.filter { !seen.contains($0.name.lowercased()) }
    }

    func next() -> CreditDeck {
        var row: Credit
        while !pending.isEmpty && seen.contains(pending[0].name.lowercased()) { pending.removeFirst() }
        if !pending.isEmpty { row = pending.removeFirst() }
        else {
            repeat {
                row = Credits.fresh(task: task, index: fallbackIndex)
                fallbackIndex += 1
            } while seen.contains(row.name.lowercased())
        }
        let key = row.name.lowercased()
        seen.insert(key)
        history.append(key)
        if history.count > 256 { seen.remove(history.removeFirst()) }
        emitted += 1
        return CreditDeck(task: task, credits: [row])
    }
}
