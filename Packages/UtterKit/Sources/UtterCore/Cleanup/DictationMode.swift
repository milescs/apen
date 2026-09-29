/// How the optional LLM cleanup should shape a dictation: a coding prompt, an email, a chat message…
///
/// Every mode shares the same faithfulness rules (keep every detail, never answer the text); a mode adds
/// context about the destination, style guidance and its own few-shot examples. `raw` skips cleanup.
public struct DictationMode: Sendable, Hashable, Identifiable {
    public struct Example: Sendable, Hashable {
        public let transcript: String
        public let cleaned: String
    }

    public let id: String
    public let name: String
    /// SF Symbol name.
    public let symbol: String
    public let summary: String
    /// False for `raw`: only dictionary replacements are applied.
    public let cleans: Bool
    /// Completes "The text … was dictated by the user … It is ___".
    let destination: String
    let guidance: [String]
    let examples: [Example]
    /// Condensing modes (notes) may legitimately drop more words than a plain cleanup.
    public let condenses: Bool
    /// Bundle identifiers of apps where this mode switches on automatically.
    public let defaultApps: [String]

    public static let coding = DictationMode(
        id: "coding",
        name: "Coding",
        symbol: "chevron.left.forwardslash.chevron.right",
        summary: "Prompts for AI coding tools: exact identifiers, file names and commands, clear structure",
        cleans: true,
        destination: "a prompt the user will send to an AI coding assistant such as Claude Code, Cursor or Codex",
        guidance: [
            """
            Keep every technical detail exact: code identifiers, file names, paths, commands, flags, package, \
            library, API and product names, versions, numbers and error messages.
            """,
            """
            Write technical tokens the way a developer types them and wrap them in backticks, converting spoken \
            forms: "app dot tsx" becomes `app.tsx`, "src slash components" becomes `src/components`, "dash dash \
            force" becomes `--force`, "use effect" becomes `useEffect`, and a function or variable named out \
            loud becomes the identifier it clearly refers to.
            """,
            """
            When the speaker lists steps, requirements or constraints, format them as a numbered or bulleted \
            list; otherwise keep plain sentences.
            """,
            "Keep it phrased as a request to the assistant. Do not write code and do not add requirements.",
        ],
        examples: [
            Example(
                transcript: """
                    um so in app dot tsx can you uh refactor the use effect hook so it like doesn't re-run on \
                    every render and also add a test for it in the tests folder
                    """,
                cleaned: """
                    In `app.tsx`, can you refactor the `useEffect` hook so it doesn't re-run on every render? \
                    Also add a test for it in the `tests` folder.
                    """
            ),
            Example(
                transcript: """
                    okay so there's a bug where uh get user returns null when the session expires so first \
                    check the token refresh logic second add some logging and third write a regression test \
                    and uh don't touch the database schema
                    """,
                cleaned: """
                    There's a bug where `getUser` returns null when the session expires.

                    1. Check the token refresh logic.
                    2. Add some logging.
                    3. Write a regression test.

                    Don't touch the database schema.
                    """
            ),
            Example(
                transcript: """
                    um so can you uh write me a python function that like reverses a string and uh make it \
                    handle unicode
                    """,
                cleaned: "Can you write me a Python function that reverses a string and make it handle Unicode?"
            ),
        ],
        condenses: false,
        defaultApps: [
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf", "dev.zed.Zed", "com.apple.dt.Xcode", "com.apple.Terminal",
            "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
            "com.github.wez.wezterm", "com.jetbrains.intellij", "com.jetbrains.WebStorm", "com.jetbrains.pycharm",
            "com.jetbrains.goland", "com.google.android.studio", "com.anthropic.claudefordesktop",
            "com.openai.chat", "com.openai.codex",
        ]
    )

    public static let general = DictationMode(
        id: "general",
        name: "General",
        symbol: "text.bubble",
        summary: "Light cleanup for anything: fillers out, punctuation fixed, wording kept",
        cleans: true,
        destination: "a message the user will send to an AI assistant or to another person",
        guidance: ["Use paragraphs or a bulleted list only if the speaker clearly dictated a list."],
        examples: [
            Example(
                transcript: """
                    um so i was thinking we could uh we could move the the standup to thursday at like 10 no \
                    wait 11 because uh friday doesn't really work for for priya you know
                    """,
                cleaned: """
                    I was thinking we could move the standup to Thursday at 11, because Friday doesn't really \
                    work for Priya.
                    """
            ),
            Example(
                transcript: """
                    um so can you uh write me a python function that like reverses a string and uh make it \
                    handle unicode
                    """,
                cleaned: "Can you write me a Python function that reverses a string and make it handle Unicode?"
            ),
        ],
        condenses: false,
        defaultApps: []
    )

    public static let writing = DictationMode(
        id: "writing",
        name: "Writing",
        symbol: "doc.richtext",
        summary: "Polished prose for documents and posts, in your own voice",
        cleans: true,
        destination: "prose for a document, article or post the user is writing",
        guidance: [
            "Produce polished, grammatical prose while keeping the author's voice, word choices and every point.",
            "Start a new paragraph where the speaker moves to a new topic.",
            "Do not add headings, embellishments or conclusions the speaker didn't dictate.",
        ],
        examples: [
            Example(
                transcript: """
                    so the thing about uh local models is that they've gotten really good um especially for \
                    speech and the the latency is basically zero now which honestly changes how you work \
                    anyway the other thing is privacy nothing leaves your machine
                    """,
                cleaned: """
                    The thing about local models is that they've gotten really good, especially for speech, and \
                    the latency is basically zero now, which honestly changes how you work.

                    The other thing is privacy: nothing leaves your machine.
                    """
            ),
        ],
        condenses: false,
        defaultApps: ["com.apple.iWork.Pages", "com.microsoft.Word", "notion.id", "com.apple.TextEdit", "com.ulyssesapp.mac", "abnerworks.Typora"]
    )

    public static let message = DictationMode(
        id: "message",
        name: "Message",
        symbol: "message",
        summary: "Casual chat for Slack, Messages and the like",
        cleans: true,
        destination: "a casual chat message (Slack, iMessage, WhatsApp) to a colleague or friend",
        guidance: [
            "Keep it casual, short and in the speaker's tone; light punctuation is fine.",
            "Do not add a greeting, sign-off or paragraphs that weren't dictated.",
        ],
        examples: [
            Example(
                transcript: "hey um are we still on for lunch tomorrow uh i can do like 12 30 if that works",
                cleaned: "Hey, are we still on for lunch tomorrow? I can do 12:30 if that works."
            ),
        ],
        condenses: false,
        defaultApps: [
            "com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "ru.keepcoder.Telegram",
            "net.whatsapp.WhatsApp", "com.microsoft.teams2", "us.zoom.xos",
        ]
    )

    public static let email = DictationMode(
        id: "email",
        name: "Email",
        symbol: "envelope",
        summary: "Well-formed emails with greeting, paragraphs and sign-off when dictated",
        cleans: true,
        destination: "an email the user will send",
        guidance: [
            "Format as an email: put a dictated greeting on its own line, use short paragraphs, and put a dictated sign-off on its own lines.",
            "Do not invent a greeting, sign-off, names or details that weren't dictated.",
        ],
        examples: [
            Example(
                transcript: """
                    hi sarah um thanks for sending the contract over i had a quick look and uh the payment terms \
                    look fine but can we change the start date to october first thanks miles
                    """,
                cleaned: """
                    Hi Sarah,

                    Thanks for sending the contract over. I had a quick look, and the payment terms look fine, \
                    but can we change the start date to October 1?

                    Thanks,
                    Miles
                    """
            ),
        ],
        condenses: false,
        defaultApps: [
            "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
            "com.mimestream.Mimestream",
        ]
    )

    public static let notes = DictationMode(
        id: "notes",
        name: "Notes",
        symbol: "list.bullet",
        summary: "Concise bullet points that keep every fact",
        cleans: true,
        destination: "notes the user is taking for themselves",
        guidance: [
            "Turn it into concise bullet points, one idea per bullet, in the speaker's words.",
            "Keep every fact, name, number, date and action item; drop only fillers and repetition.",
            "No title or introduction.",
        ],
        examples: [
            Example(
                transcript: """
                    okay so notes from the call um the launch is moving to march 3rd uh jen owns the pricing \
                    page and we still need legal to sign off on the terms also the beta has 40 users now
                    """,
                cleaned: """
                    - Launch is moving to March 3.
                    - Jen owns the pricing page.
                    - Legal still needs to sign off on the terms.
                    - The beta has 40 users now.
                    """
            ),
        ],
        condenses: true,
        defaultApps: ["com.apple.Notes", "md.obsidian", "com.agiletortoise.Drafts-OSX", "net.shinyfrog.bear"]
    )

    public static let raw = DictationMode(
        id: "raw",
        name: "Raw",
        symbol: "waveform",
        summary: "No LLM cleanup — the transcript with your dictionary applied",
        cleans: false,
        destination: "",
        guidance: [],
        examples: [],
        condenses: false,
        defaultApps: []
    )

    public static let builtIn: [DictationMode] = [.coding, .general, .writing, .message, .email, .notes, .raw]
    public static let defaultModeID = coding.id

    public static func mode(id: String) -> DictationMode? {
        builtIn.first { $0.id == id }
    }

    /// The mode to use for a dictation into the app with `bundleID`: a mode whose app list contains the app
    /// wins; otherwise the user's selected mode.
    ///
    /// - Parameter apps: the effective app list for each mode id (user edits or the defaults).
    public static func resolve(bundleID: String?, selectedID: String, apps: [String: [String]]) -> (mode: DictationMode, automatic: Bool) {
        let selected = mode(id: selectedID) ?? .coding
        guard let bundleID else { return (selected, false) }
        for candidate in builtIn where (apps[candidate.id] ?? candidate.defaultApps).contains(bundleID) {
            return (candidate, candidate.id != selected.id)
        }
        return (selected, false)
    }
}
