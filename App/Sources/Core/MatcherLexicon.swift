import Foundation

/// Word tables for `FuzzyMatcher`: what a person says versus what a rule says. Data only.
enum MatcherLexicon {
    /// Query word -> command words that mean the same thing. Small and general on purpose: spelling variants
    /// and near-universal stand-ins ("everything" for all, "fresh" for new), not per-command aliases.
    static let synonyms: [String: [String]] = [
        "everything": ["all"], "minimise": ["minimize"], "maximise": ["maximize"], "shut": ["close"],
        "exit": ["quit"], "refresh": ["reload"], "reload": ["refresh"], "start": ["launch", "run"],
        "begin": ["start"], "remove": ["delete", "close"], "erase": ["delete"], "discard": ["delete", "close"],
        "dismiss": ["close"], "restore": ["reopen"], "louder": ["volume", "up"],
        "quieter": ["volume", "down"],
        "fresh": ["new"], "fill": ["maximize", "full"], "end": ["bottom", "last"], "usage": ["references"],
        "rerun": ["repeat", "run"], "again": ["repeat"], "listening": ["speech", "voice", "sleep"],
        "speaker": ["sound", "volume"], "audio": ["sound", "volume"], "previous": ["last"], "prior": ["last"],
    ]

    /// Verbs people use interchangeably for the same UI action. Symmetric: any member stands in for every other
    /// member, at `synonymPenalty`, and only when the query word itself is not in the rule. Kept to verbs of one
    /// action (choose text, show, look for, remove, leave, move to), never to nouns or per-command aliases.
    static let verbClasses: [[String]] = [
        ["select", "highlight", "choose", "pick", "grab"],
        ["show", "display", "reveal"],
        ["find", "search", "locate"],
        ["delete", "remove", "erase", "wipe", "discard", "ditch", "scrap"],
        ["quit", "exit", "leave"],
        ["go", "jump", "navigate"],
        ["increase", "raise", "boost"],
        ["decrease", "reduce", "lower"],
        ["stop", "halt", "cancel", "abort", "terminate", "kill", "interrupt"],
        ["close", "shut", "dismiss"],
        ["create", "new", "add"],
        ["copy", "duplicate", "clone"],
        ["cut", "snip", "chop"],
        ["undo", "revert", "rollback"],
        ["format", "beautify", "tidy", "prettify", "reformat"],
        ["forward", "ahead", "onward"],
        ["back", "backward", "earlier"],
        ["go", "hop", "head"],
        ["hide", "conceal"],
        ["pause", "freeze", "suspend"],
        ["rename", "retitle"],
        ["bookmark", "favorite", "save"],
        ["split", "divide", "slice", "separate"],
        ["outdent", "unindent", "dedent"],
    ]

    /// Nouns people use for the same thing in an interface. Symmetric like `verbClasses`, and likewise only a
    /// stand-in when the query word itself is not in the rule.
    static let nounClasses: [[String]] = [
        ["pane", "split", "section", "panel", "area", "region"],
        ["terminal", "shell", "console", "prompt"],
        ["trash", "bin", "garbage", "recycle"],
        ["meeting", "call", "conference"],
        ["email", "mail", "message", "inbox"],
        ["address", "url", "link", "location"],
        ["definition", "declaration", "source"],
        ["application", "app", "program", "software"],
        ["settings", "preferences", "options", "config", "configuration"],
        ["document", "file", "doc"],
        ["page", "article", "website", "site", "webpage"],
        ["volume", "sound", "audio", "loudness"],
        ["screen", "display", "monitor"],
        ["tab", "page"],
        ["process", "task", "job", "program"],
        ["breakpoint", "stop"],
        ["picture", "image", "photo"],
        ["note", "memo"],
        ["reference", "usage", "usages", "references"],
        ["symbol", "identifier", "variable", "name"],
        ["hand", "attention"],
        ["mode", "view", "layout"],
    ]

    /// Query word -> command words it implies in one direction (a bigger window is a maximized one). Several words
    /// here are a set of hints, not alternatives: the more of them a rule has, the better it fits.
    static let implications: [String: [String]] = [
        "bigger": ["zoom", "in", "maximize"], "larger": ["zoom", "in", "maximize"], "enlarge": ["zoom", "in", "maximize"],
        "expand": ["zoom", "in", "maximize"], "grow": ["zoom", "in", "maximize"],
        "smaller": ["zoom", "out", "minimize"], "shrink": ["zoom", "out", "minimize"], "tiny": ["zoom", "out", "minimize"],
        "compress": ["zoom", "out", "minimize"],
        "frozen": ["kill", "force", "quit"], "stuck": ["kill", "force", "quit"], "unresponsive": ["kill", "force", "quit"],
        "hung": ["kill", "force", "quit"], "silence": ["mute"], "silent": ["mute"],
    ]

    /// App-name word -> what kind of app it is, so "the terminal" reaches WezTerm's commands. Lower case.
    static let appKinds: [String: [String]] = [
        "wezterm": ["terminal", "shell"], "iterm": ["terminal", "shell"], "iterm2": ["terminal", "shell"],
        "terminal": ["terminal", "shell"], "kitty": ["terminal", "shell"], "alacritty": ["terminal", "shell"],
        "warp": ["terminal", "shell"], "ghostty": ["terminal", "shell"],
        "code": ["editor", "code"], "vscode": ["editor", "code"], "xcode": ["editor", "code"],
        "cursor": ["editor", "code"], "intellij": ["editor", "code"], "pycharm": ["editor", "code"],
        "sublime": ["editor", "code"], "vim": ["editor", "code"], "emacs": ["editor", "code"],
        "chrome": ["browser", "web"], "safari": ["browser", "web"], "firefox": ["browser", "web"],
        "arc": ["browser", "web"], "brave": ["browser", "web"], "edge": ["browser", "web"],
        "zoom": ["meeting", "call", "video"], "teams": ["meeting", "call", "video"], "webex": ["meeting", "call"],
        "meet": ["meeting", "call", "video"],
        "mail": ["email", "inbox", "message"], "outlook": ["email", "inbox", "message"],
        "calendar": ["calendar", "schedule", "event"], "notes": ["note", "memo"],
        "finder": ["file", "folder"], "spotify": ["music", "song", "track"], "music": ["music", "song", "track"],
        "slack": ["chat", "message"], "messages": ["chat", "message"], "discord": ["chat", "message"],
    ]

    /// Query word -> command words, from `synonyms` plus the symmetric `verbClasses`.
    static let thesaurus: [String: [String]] = {
        var table = synonyms
        for group in verbClasses + nounClasses {
            for word in group {
                for other in group where other != word && !(table[word]?.contains(other) ?? false) {
                    table[word, default: []].append(other)
                }
            }
        }
        // Direction a verb implies, for "increase the volume"-style requests.
        for (verb, words) in [("increase", ["up"]), ("raise", ["up"]), ("boost", ["up"]),
                              ("decrease", ["down"]), ("reduce", ["down"]), ("lower", ["down"]),
                              ("revert", ["undo"]), ("disappear", ["close", "hide", "delete"]),
                              ("vanish", ["close", "hide", "delete"])] {
            table[verb, default: []].append(contentsOf: words)
        }
        for (word, words) in implications { table[word, default: []].append(contentsOf: words) }
        return table
    }()
}
