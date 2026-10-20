import Foundation

/// The word tables behind `ConceptLinks`. Data only: general English and interface vocabulary (opposites, what undoes
/// what, which everyday word points at which interface word), never a command's id or a whole phrase.
enum ConceptLinkData {
    /// Opposites. Each pair works both ways: "the opposite of indent" is outdent, "the opposite of outdent" is indent.
    static let antonymPairs: [(String, String)] = [
        ("undo", "redo"), ("open", "close"), ("show", "hide"), ("left", "right"), ("up", "down"), ("in", "out"),
        ("next", "previous"), ("forward", "back"), ("indent", "outdent"), ("mute", "unmute"), ("start", "stop"),
        ("enable", "disable"), ("lock", "unlock"), ("wake", "sleep"), ("raise", "lower"), ("top", "bottom"),
        ("first", "last"), ("increase", "decrease"), ("louder", "quieter"), ("bigger", "smaller"),
        ("expand", "collapse"), ("maximize", "minimize"), ("play", "pause"), ("add", "remove"), ("on", "off"),
        ("begin", "end"), ("attach", "detach"), ("connect", "disconnect"), ("join", "leave"), ("select", "deselect"),
        ("pin", "unpin"), ("fold", "unfold"), ("accept", "reject"), ("push", "pull"),
    ]

    /// The command word that undoes what a verb did, for "put back what I closed" and "undo the undo". Regular forms
    /// (closing, closed) are reached through the stems; irregular ones are in `forms`.
    static let reversals: [String: String] = [
        "close": "reopen", "quit": "reopen", "undo": "redo", "delete": "undo", "remove": "undo", "paste": "undo",
        "type": "undo", "cut": "undo", "hide": "show", "mute": "unmute", "lock": "unlock", "minimize": "maximize",
    ]

    /// Odd forms of table words: form -> base.
    static let forms: [String: String] = [
        "undid": "undo", "undone": "undo", "shut": "close", "hidden": "hide", "gone": "delete", "quieter": "quiet",
    ]

    /// Phrases that turn the words around them into their opposite ("the opposite of X"). The phrase is dropped.
    static let oppositeMarkers: [[String]] = [
        ["the", "opposite", "of"], ["opposite", "of"], ["opposite", "to"], ["opposite"], ["inverse", "of"], ["inverse"],
        ["reverse", "of"], ["reversal", "of"],
    ]

    /// Phrases that ask to take back what a verb did ("put back the tab I closed"). The phrase is dropped.
    static let undoMarkers: [[String]] = [
        ["put", "back"], ["bring", "back"], ["get", "back"], ["take", "back"], ["roll", "back"], ["rollback"],
        ["undoing"], ["undo"], ["revert"], ["restore"], ["reversing"], ["reverse"],
    ]

    /// After the thing reversed ("I pasted it and need that reversed").
    static let trailingMarkers: Set<String> = ["reversed", "reverted", "undone", "undid"]

    /// Everyday word -> interface words it points at. One way: what a person says, to what rules say. Where several
    /// words are listed they are hints that fit a rule better the more of them it has ("night" -> dark, mode).
    static let concepts: [String: [String]] = [
        // Appearance and display
        "wallpaper": ["desktop"], "backdrop": ["desktop"], "background": ["desktop"],
        "night": ["dark", "mode"], "nighttime": ["dark", "mode"], "evening": ["dark", "mode"], "eyes": ["dark", "mode"],
        "dim": ["dark", "mode"], "theme": ["dark", "mode"], "darker": ["dark", "mode"],
        "pretty": ["format"], "neat": ["format"], "prettier": ["format"], "tidier": ["format"],
        // Capture and selection
        "capture": ["screenshot"], "snapshot": ["screenshot"], "screengrab": ["screenshot"], "screencap": ["screenshot"],
        "part": ["area", "selection"], "portion": ["area", "selection"], "piece": ["area", "selection"],
        "region": ["area", "selection"], "whole": ["all"], "entire": ["all"], "complete": ["all"],
        "copied": ["clipboard"], "clips": ["clipboard"], "recent": ["history"], "recently": ["history"],
        "past": ["history"],
        // Developer vocabulary
        "inspector": ["developer", "tools"], "devtools": ["developer", "tools"], "inspect": ["developer", "tools"],
        "squiggle": ["fix"], "correction": ["fix"], "suggestion": ["fix"], "error": ["fix"], "problem": ["fix"],
        "explorer": ["sidebar"], "navigator": ["sidebar"], "drawer": ["sidebar"],
        "row": ["line"], "rows": ["line"], "repeat": ["duplicate"], "twin": ["duplicate"],
        // Emoji and symbols
        "smiley": ["emoji"], "smilies": ["emoji"], "emoticon": ["emoji"], "emojis": ["emoji"],
        // Position and direction
        "below": ["down"], "underneath": ["down"], "beneath": ["down"], "downward": ["down"], "downwards": ["down"],
        "above": ["up"], "upward": ["up"], "upwards": ["up"], "beginning": ["top"],
        "screenful": ["page"], "screenfuls": ["page"], "front": ["focus"], "foreground": ["focus"],
        "cycle": ["next"], "rotate": ["next"], "other": ["next"], "another": ["new"],
        // Sound and people
        "hearing": ["mute"], "muffle": ["mute"], "tuck": ["minimize"],
    ]
}
