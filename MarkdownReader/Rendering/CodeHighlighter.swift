import AppKit

/// Language-aware syntax highlighting for fenced code blocks in the reader.
///
/// A small table-driven tokenizer (keywords, types, literals, comments,
/// strings, numbers, function calls, plus dedicated modes for markup, diff,
/// JSON/YAML/TOML, CSS and shell) instead of a full grammar engine: it is
/// fast enough for live preview and covers the languages that appear in
/// Markdown documents. Unknown languages are shown uncolored.
enum CodeHighlighter {
    enum Token {
        case keyword, type, literal, string, number, comment, function, attribute, tag, preprocessor, variable
        case inserted, deleted, meta

        var color: NSColor {
            switch self {
            case .keyword: return Colors.keyword
            case .type: return Colors.type
            case .literal: return Colors.keyword
            case .string: return Colors.string
            case .number: return Colors.number
            case .comment: return Colors.comment
            case .function: return Colors.function
            case .attribute: return Colors.attribute
            case .tag: return Colors.tag
            case .preprocessor: return Colors.preprocessor
            case .variable: return Colors.variable
            case .inserted: return Colors.inserted
            case .deleted: return Colors.deleted
            case .meta: return Colors.meta
            }
        }
    }

    /// Xcode-like default theme, dynamic for Light and Dark Mode.
    enum Colors {
        static let keyword = RenderColors.dynamic(light: rgb(0x9B2393), dark: rgb(0xFC5FA3))
        static let type = RenderColors.dynamic(light: rgb(0x3900A0), dark: rgb(0xD0A8FF))
        static let string = RenderColors.dynamic(light: rgb(0xC41A16), dark: rgb(0xFC6A5D))
        static let number = RenderColors.dynamic(light: rgb(0x1C00CF), dark: rgb(0xD0BF69))
        static let comment = RenderColors.dynamic(light: rgb(0x5D6C79), dark: rgb(0x7F8C98))
        static let function = RenderColors.dynamic(light: rgb(0x326D74), dark: rgb(0x67B7A4))
        static let attribute = RenderColors.dynamic(light: rgb(0x815F03), dark: rgb(0xE5C07B))
        static let tag = RenderColors.dynamic(light: rgb(0x0B4F79), dark: rgb(0x5DD8FF))
        static let preprocessor = RenderColors.dynamic(light: rgb(0x643820), dark: rgb(0xFD8F3F))
        static let variable = RenderColors.dynamic(light: rgb(0x0F68A0), dark: rgb(0x41A1C0))
        static let inserted = RenderColors.dynamic(light: rgb(0x1A7F37), dark: rgb(0x7EE787))
        static let deleted = RenderColors.dynamic(light: rgb(0xCF222E), dark: rgb(0xFF7B72))
        static let meta = RenderColors.dynamic(light: rgb(0x8250DF), dark: rgb(0xD2A8FF))

        private static func rgb(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
    }

    /// Returns colored ranges (UTF-16 offsets into `code`), or nil for an
    /// unknown language.
    static func highlight(_ code: String, language info: String) -> [(NSRange, Token)]? {
        let name = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init)?
            .lowercased() ?? ""
        guard let language = Language.named(name) else { return nil }
        let chars = Array(code.utf16)
        switch language.mode {
        case .diff: return diff(chars)
        case .markup: return markup(chars)
        default:
            var scanner = Scanner(chars: chars, language: language)
            scanner.run()
            return scanner.tokens
        }
    }

    // MARK: - Languages

    struct Language {
        enum Mode { case code, markup, diff, json, yaml, toml, css, shell, sql }

        var mode: Mode = .code
        var keywords: Set<String> = []
        var types: Set<String> = []
        var literals: Set<String> = ["true", "false"]
        var lineComments: [String] = []
        var blockComments: [(String, String)] = []
        var quotes: [String] = ["\"", "'"]
        var multilineQuotes: [String] = []
        var capitalizedTypes = true
        var preprocessor = false
        var variablePrefixes: Set<UInt16> = []
        var annotationPrefix: UInt16?
        var identifierExtra: Set<UInt16> = [0x5F] // _
        var caseInsensitive = false

        static func named(_ name: String) -> Language? {
            switch name {
            case "swift": return swift
            case "objc", "objective-c", "objectivec", "m", "mm", "obj-c": return objc
            case "c", "h": return c
            case "cpp", "c++", "cc", "cxx", "hpp", "hh", "hxx", "ino", "arduino": return cpp
            case "cs", "csharp", "c#": return csharp
            case "java": return java
            case "kotlin", "kt", "kts": return kotlin
            case "scala", "sc": return scala
            case "go", "golang": return go
            case "rust", "rs": return rust
            case "dart": return dart
            case "js", "javascript", "jsx", "mjs", "cjs", "node", "es6": return javascript
            case "ts", "typescript", "tsx", "mts", "cts": return typescript
            case "json", "jsonc", "json5", "geojson", "jsonl": return json
            case "py", "python", "python3", "py3", "gyp", "pyi", "sage": return python
            case "rb", "ruby", "gemspec", "podspec", "rake": return ruby
            case "php": return php
            case "pl", "perl", "pm": return perl
            case "lua": return lua
            case "r", "rscript": return rLang
            case "sh", "bash", "zsh", "shell", "fish", "ksh", "console", "shellsession", "shell-session", "terminal",
                 "bat", "cmd", "batch":
                return shell
            case "ps1", "powershell", "pwsh", "psm1": return powershell
            case "sql", "mysql", "postgresql", "postgres", "psql", "sqlite", "plsql", "tsql", "mssql": return sql
            case "yaml", "yml": return yaml
            case "toml", "ini", "cfg", "conf", "properties", "editorconfig", "gitconfig", "env", "dotenv": return toml
            case "html", "htm", "xhtml", "xml", "plist", "svg", "xsl", "xslt", "rss", "atom", "vue", "svelte",
                 "xaml", "csproj", "storyboard", "xib", "wsdl", "mathml":
                return Language(mode: .markup)
            case "css", "scss", "sass", "less", "stylus": return css
            case "diff", "patch", "udiff": return Language(mode: .diff)
            case "dockerfile", "docker", "containerfile": return dockerfile
            case "makefile", "make", "mk", "gnumakefile", "cmake": return makefile
            case "hs", "haskell": return haskell
            case "ex", "exs", "elixir": return elixir
            case "graphql", "gql": return graphql
            case "tex", "latex": return Language(keywords: [], literals: [], lineComments: ["%"], quotes: [],
                                                 capitalizedTypes: false)
            case "nginx", "apache", "apacheconf": return Language(mode: .shell, lineComments: ["#"], capitalizedTypes: false)
            default: return nil
            }
        }

        private static let cFamilyKeywords: Set<String> = [
            "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
            "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
            "volatile", "while", "_Bool", "_Complex", "bool",
        ]

        static let c = Language(keywords: cFamilyKeywords, types: ["size_t", "uint8_t", "uint16_t", "uint32_t",
                                "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t", "FILE", "ssize_t", "wchar_t"],
                                literals: ["true", "false", "NULL"], lineComments: ["//"], blockComments: [("/*", "*/")],
                                capitalizedTypes: false, preprocessor: true)

        static let cpp = Language(keywords: cFamilyKeywords.union([
            "alignas", "alignof", "and", "asm", "catch", "class", "concept", "constexpr", "consteval", "const_cast",
            "co_await", "co_return", "co_yield", "decltype", "delete", "dynamic_cast", "explicit", "export", "friend",
            "mutable", "namespace", "new", "noexcept", "not", "operator", "or", "private", "protected", "public",
            "reinterpret_cast", "requires", "static_assert", "static_cast", "template", "this", "thread_local",
            "throw", "try", "typeid", "typename", "using", "virtual", "override", "final",
        ]), types: ["string", "vector", "map", "set", "unique_ptr", "shared_ptr", "size_t", "std", "uint8_t",
                    "uint32_t", "int32_t", "int64_t", "uint64_t"],
            literals: ["true", "false", "nullptr", "NULL"], lineComments: ["//"], blockComments: [("/*", "*/")],
            preprocessor: true)

        static let objc = Language(keywords: cFamilyKeywords.union([
            "@interface", "@implementation", "@end", "@property", "@synthesize", "@protocol", "@optional",
            "@required", "@class", "@selector", "@autoreleasepool", "@try", "@catch", "@finally", "@throw",
            "@import", "@dynamic", "self", "super", "id", "instancetype", "nonatomic", "atomic", "strong", "weak",
            "copy", "assign", "readonly", "readwrite", "nullable", "nonnull", "__block", "__weak", "IBOutlet",
            "IBAction",
        ]), literals: ["YES", "NO", "nil", "Nil", "NULL", "true", "false"], lineComments: ["//"],
            blockComments: [("/*", "*/")], preprocessor: true, identifierExtra: [0x5F, 0x40])

        static let swift = Language(keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
            "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
            "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
            "infix", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating", "nonisolated",
            "nonmutating", "open", "operator", "optional", "override", "package", "postfix", "precedencegroup",
            "prefix", "private", "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self",
            "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try", "typealias",
            "unowned", "var", "weak", "where", "while", "willSet", "consume", "borrowing", "consuming", "sending",
        ], literals: ["true", "false", "nil"], lineComments: ["//"], blockComments: [("/*", "*/")],
            quotes: ["\""], multilineQuotes: ["\"\"\""], annotationPrefix: 0x40, identifierExtra: [0x5F, 0x23])

        static let csharp = Language(keywords: [
            "abstract", "as", "async", "await", "base", "bool", "break", "byte", "case", "catch", "char", "checked",
            "class", "const", "continue", "decimal", "default", "delegate", "do", "double", "else", "enum", "event",
            "explicit", "extern", "finally", "fixed", "float", "for", "foreach", "get", "goto", "if", "implicit",
            "in", "init", "int", "interface", "internal", "is", "lock", "long", "namespace", "new", "object",
            "operator", "out", "override", "params", "partial", "private", "protected", "public", "readonly",
            "record", "ref", "return", "sbyte", "sealed", "set", "short", "sizeof", "stackalloc", "static", "string",
            "struct", "switch", "this", "throw", "try", "typeof", "uint", "ulong", "unchecked", "unsafe", "ushort",
            "using", "var", "virtual", "void", "volatile", "when", "where", "while", "yield",
        ], literals: ["true", "false", "null"], lineComments: ["//"], blockComments: [("/*", "*/")],
            quotes: ["\"", "'"], multilineQuotes: ["\"\"\""], preprocessor: true)

        static let java = Language(keywords: [
            "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
            "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "goto", "if",
            "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private",
            "protected", "public", "record", "return", "sealed", "short", "static", "strictfp", "super", "switch",
            "synchronized", "this", "throw", "throws", "transient", "try", "var", "void", "volatile", "while",
            "yield", "permits",
        ], literals: ["true", "false", "null"], lineComments: ["//"], blockComments: [("/*", "*/")],
            multilineQuotes: ["\"\"\""], annotationPrefix: 0x40)

        static let kotlin = Language(keywords: [
            "abstract", "actual", "annotation", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "crossinline", "data", "do", "else", "enum", "expect", "external", "final",
            "finally", "for", "fun", "get", "if", "import", "in", "infix", "init", "inline", "inner", "interface",
            "internal", "is", "lateinit", "noinline", "object", "open", "operator", "out", "override", "package",
            "private", "protected", "public", "reified", "return", "sealed", "set", "super", "suspend", "this",
            "throw", "try", "typealias", "val", "var", "vararg", "when", "where", "while", "value",
        ], literals: ["true", "false", "null"], lineComments: ["//"], blockComments: [("/*", "*/")],
            multilineQuotes: ["\"\"\""], annotationPrefix: 0x40)

        static let scala = Language(keywords: [
            "abstract", "case", "catch", "class", "def", "do", "else", "enum", "extends", "final", "finally", "for",
            "forSome", "given", "if", "implicit", "import", "lazy", "match", "new", "object", "override", "package",
            "private", "protected", "return", "sealed", "super", "then", "this", "throw", "trait", "try", "type",
            "using", "val", "var", "while", "with", "yield",
        ], literals: ["true", "false", "null"], lineComments: ["//"], blockComments: [("/*", "*/")],
            multilineQuotes: ["\"\"\""], annotationPrefix: 0x40)

        static let go = Language(keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func",
            "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var",
        ], types: ["bool", "byte", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
                   "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr", "any"],
            literals: ["true", "false", "nil", "iota"], lineComments: ["//"], blockComments: [("/*", "*/")],
            quotes: ["\"", "'"], multilineQuotes: ["`"], capitalizedTypes: false)

        static let rust = Language(keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn",
            "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self",
            "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while", "union",
        ], types: ["i8", "i16", "i32", "i64", "i128", "isize", "u8", "u16", "u32", "u64", "u128", "usize", "f32",
                   "f64", "bool", "char", "str", "String", "Vec", "Option", "Result", "Box"],
            literals: ["true", "false", "None", "Some", "Ok", "Err"], lineComments: ["//"],
            blockComments: [("/*", "*/")], quotes: ["\""], annotationPrefix: 0x23)

        static let dart = Language(keywords: [
            "abstract", "as", "assert", "async", "await", "break", "case", "catch", "class", "const", "continue",
            "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends", "extension",
            "external", "factory", "final", "finally", "for", "get", "if", "implements", "import", "in", "interface",
            "is", "late", "library", "mixin", "new", "on", "operator", "part", "required", "rethrow", "return",
            "sealed", "set", "static", "super", "switch", "sync", "this", "throw", "try", "typedef", "var", "void",
            "while", "with", "yield",
        ], literals: ["true", "false", "null"], lineComments: ["//"], blockComments: [("/*", "*/")],
            multilineQuotes: ["\"\"\"", "'''"], annotationPrefix: 0x40)

        static let javascriptKeywords: Set<String> = [
            "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete",
            "do", "else", "export", "extends", "finally", "for", "from", "function", "get", "if", "import", "in",
            "instanceof", "let", "new", "of", "return", "set", "static", "super", "switch", "this", "throw", "try",
            "typeof", "var", "void", "while", "with", "yield",
        ]

        static let javascript = Language(keywords: javascriptKeywords,
                                         types: ["Array", "Object", "String", "Number", "Boolean", "Promise", "Map",
                                                 "Set", "Date", "RegExp", "Error", "JSON", "Math", "console", "window",
                                                 "document"],
                                         literals: ["true", "false", "null", "undefined", "NaN", "Infinity"],
                                         lineComments: ["//"], blockComments: [("/*", "*/")],
                                         multilineQuotes: ["`"], variablePrefixes: [0x24], annotationPrefix: 0x40,
                                         identifierExtra: [0x5F, 0x24])

        static let typescript = Language(keywords: javascriptKeywords.union([
            "abstract", "any", "as", "asserts", "boolean", "declare", "enum", "implements", "infer", "interface",
            "is", "keyof", "module", "namespace", "never", "number", "object", "private", "protected", "public",
            "readonly", "satisfies", "string", "symbol", "type", "unique", "unknown", "override",
        ]), literals: ["true", "false", "null", "undefined", "NaN", "Infinity"], lineComments: ["//"],
            blockComments: [("/*", "*/")], multilineQuotes: ["`"], annotationPrefix: 0x40,
            identifierExtra: [0x5F, 0x24])

        static let json = Language(mode: .json, literals: ["true", "false", "null"], lineComments: ["//"],
                                   blockComments: [("/*", "*/")], quotes: ["\""], capitalizedTypes: false)

        static let python = Language(keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else",
            "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "case",
            "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "self", "cls",
        ], types: ["int", "float", "str", "bool", "list", "dict", "set", "tuple", "bytes", "object", "type",
                   "print", "len", "range", "open", "super", "isinstance", "enumerate", "zip", "map", "filter"],
            literals: ["True", "False", "None"], lineComments: ["#"], quotes: ["\"", "'"],
            multilineQuotes: ["\"\"\"", "'''"], annotationPrefix: 0x40)

        static let ruby = Language(keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
            "ensure", "for", "if", "in", "module", "next", "not", "or", "redo", "rescue", "retry", "return", "self",
            "super", "then", "undef", "unless", "until", "when", "while", "yield", "require", "attr_accessor",
            "attr_reader", "attr_writer", "private", "protected", "public", "puts", "lambda", "proc",
        ], literals: ["true", "false", "nil"], lineComments: ["#"], blockComments: [("=begin", "=end")],
            variablePrefixes: [0x40, 0x24], identifierExtra: [0x5F, 0x3F, 0x21])

        static let php = Language(keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class", "clone", "const",
            "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare", "endfor",
            "endforeach", "endif", "endswitch", "endwhile", "enum", "extends", "final", "finally", "fn", "for",
            "foreach", "function", "global", "goto", "if", "implements", "include", "include_once", "instanceof",
            "insteadof", "interface", "isset", "list", "match", "namespace", "new", "or", "print", "private",
            "protected", "public", "readonly", "require", "require_once", "return", "static", "switch", "throw",
            "trait", "try", "unset", "use", "var", "while", "xor", "yield",
        ], literals: ["true", "false", "null", "TRUE", "FALSE", "NULL"], lineComments: ["//", "#"],
            blockComments: [("/*", "*/")], variablePrefixes: [0x24])

        static let perl = Language(keywords: [
            "my", "our", "local", "sub", "if", "elsif", "else", "unless", "while", "until", "for", "foreach", "do",
            "last", "next", "redo", "return", "use", "no", "require", "package", "print", "say", "die", "eval",
            "and", "or", "not", "eq", "ne", "lt", "gt", "le", "ge", "qw", "shift", "push", "pop",
        ], literals: [], lineComments: ["#"], capitalizedTypes: false, variablePrefixes: [0x24, 0x40, 0x25])

        static let lua = Language(keywords: [
            "and", "break", "do", "else", "elseif", "end", "for", "function", "goto", "if", "in", "local", "not",
            "or", "repeat", "return", "then", "until", "while",
        ], literals: ["true", "false", "nil"], lineComments: ["--"], blockComments: [("--[[", "]]")],
            capitalizedTypes: false)

        static let rLang = Language(keywords: [
            "if", "else", "repeat", "while", "function", "for", "in", "next", "break", "library", "require",
            "return",
        ], literals: ["TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "T", "F"], lineComments: ["#"],
            capitalizedTypes: false)

        static let shell = Language(mode: .shell, keywords: [
            "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
            "function", "select", "return", "exit", "export", "local", "readonly", "declare", "unset", "source",
            "alias", "set", "shift", "break", "continue", "eval", "exec", "trap", "time",
        ], types: ["echo", "printf", "cd", "ls", "cp", "mv", "rm", "mkdir", "cat", "grep", "sed", "awk", "find",
                   "chmod", "chown", "curl", "wget", "git", "sudo", "brew", "npm", "yarn", "pip", "python", "python3",
                   "make", "docker", "xcodebuild", "swift", "open", "tar", "ssh", "test", "read", "kill", "touch"],
            literals: ["true", "false"], lineComments: ["#"], capitalizedTypes: false, variablePrefixes: [0x24],
            identifierExtra: [0x5F, 0x2D])

        static let powershell = Language(keywords: [
            "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else", "elseif", "end",
            "exit", "filter", "finally", "for", "foreach", "from", "function", "if", "in", "param", "process",
            "return", "switch", "throw", "trap", "try", "until", "using", "while",
        ], literals: ["$true", "$false", "$null"], lineComments: ["#"], blockComments: [("<#", "#>")],
            variablePrefixes: [0x24], identifierExtra: [0x5F, 0x2D], caseInsensitive: true)

        static let sql = Language(mode: .sql, keywords: [
            "add", "all", "alter", "and", "any", "as", "asc", "begin", "between", "by", "case", "cascade", "check",
            "column", "commit", "constraint", "create", "cross", "database", "default", "delete", "desc", "distinct",
            "drop", "else", "end", "exists", "foreign", "from", "full", "function", "grant", "group", "having", "if",
            "in", "index", "inner", "insert", "into", "is", "join", "key", "left", "like", "limit", "not", "null",
            "offset", "on", "or", "order", "outer", "primary", "procedure", "references", "replace", "returning",
            "returns", "revoke", "right", "rollback", "select", "set", "table", "then", "transaction", "trigger",
            "truncate", "union", "unique", "update", "using", "values", "view", "when", "where", "with", "over",
            "partition", "recursive", "language", "declare", "return", "explain",
        ], types: ["int", "integer", "bigint", "smallint", "tinyint", "serial", "bigserial", "decimal", "numeric",
                   "real", "float", "double", "varchar", "char", "text", "boolean", "bool", "date", "time",
                   "timestamp", "timestamptz", "interval", "uuid", "json", "jsonb", "blob", "bytea", "count", "sum",
                   "avg", "min", "max", "coalesce", "now"],
            literals: ["true", "false", "null"], lineComments: ["--", "#"], blockComments: [("/*", "*/")],
            quotes: ["'", "\"", "`"], capitalizedTypes: false, caseInsensitive: true)

        static let yaml = Language(mode: .yaml, literals: ["true", "false", "null", "yes", "no", "on", "off", "~"],
                                   lineComments: ["#"], capitalizedTypes: false)

        static let toml = Language(mode: .toml, literals: ["true", "false"], lineComments: ["#", ";"],
                                   multilineQuotes: ["\"\"\"", "'''"], capitalizedTypes: false)

        static let css = Language(mode: .css, keywords: ["!important", "@media", "@import", "@font-face",
                                                         "@keyframes", "@supports", "@mixin", "@include",
                                                         "@extend", "@use", "@forward", "@if", "@else", "@each",
                                                         "@return", "@function"],
                                  literals: [], lineComments: ["//"], blockComments: [("/*", "*/")],
                                  capitalizedTypes: false, variablePrefixes: [0x24, 0x40],
                                  identifierExtra: [0x5F, 0x2D])

        static let dockerfile = Language(mode: .shell, keywords: [
            "FROM", "RUN", "CMD", "LABEL", "MAINTAINER", "EXPOSE", "ENV", "ADD", "COPY", "ENTRYPOINT", "VOLUME",
            "USER", "WORKDIR", "ARG", "ONBUILD", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "AS",
        ], literals: [], lineComments: ["#"], capitalizedTypes: false, variablePrefixes: [0x24])

        static let makefile = Language(mode: .shell, keywords: [
            "ifeq", "ifneq", "ifdef", "ifndef", "else", "endif", "include", "define", "endef", "export", "override",
            ".PHONY",
        ], literals: [], lineComments: ["#"], capitalizedTypes: false, variablePrefixes: [0x24])

        static let haskell = Language(keywords: [
            "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix",
            "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "qualified",
        ], literals: ["True", "False", "Nothing", "Just"], lineComments: ["--"], blockComments: [("{-", "-}")],
            quotes: ["\""], identifierExtra: [0x5F, 0x27])

        static let elixir = Language(keywords: [
            "after", "alias", "and", "case", "catch", "cond", "def", "defp", "defmodule", "defstruct", "defmacro",
            "defimpl", "defprotocol", "do", "else", "end", "fn", "for", "if", "import", "in", "not", "or", "quote",
            "raise", "receive", "require", "rescue", "try", "unless", "unquote", "use", "when", "with",
        ], literals: ["true", "false", "nil"], lineComments: ["#"], multilineQuotes: ["\"\"\""],
            variablePrefixes: [0x40, 0x3A], identifierExtra: [0x5F, 0x3F, 0x21])

        static let graphql = Language(keywords: [
            "query", "mutation", "subscription", "fragment", "on", "type", "interface", "union", "enum", "input",
            "scalar", "schema", "extend", "implements", "directive", "repeatable",
        ], literals: ["true", "false", "null"], lineComments: ["#"], quotes: ["\""], multilineQuotes: ["\"\"\""],
            variablePrefixes: [0x24], annotationPrefix: 0x40)
    }

    // MARK: - Generic scanner

    private struct Scanner {
        let chars: [UInt16]
        let language: Language
        var tokens: [(NSRange, Token)] = []
        var i = 0
        var lineStart = true
        /// Brace depth for CSS (selectors outside, properties inside).
        var braceDepth = 0

        init(chars: [UInt16], language: Language) {
            self.chars = chars
            self.language = language
        }

        mutating func add(_ start: Int, _ end: Int, _ token: Token) {
            if end > start { tokens.append((NSRange(location: start, length: end - start), token)) }
        }

        func matches(_ s: String, at k: Int) -> Bool {
            var j = k
            for unit in s.utf16 {
                guard j < chars.count, chars[j] == unit else { return false }
                j += 1
            }
            return true
        }

        func isIdentifierStart(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F
        }

        func isIdentifierPart(_ c: UInt16) -> Bool {
            isIdentifierStart(c) || (c >= 0x30 && c <= 0x39) || language.identifierExtra.contains(c)
        }

        func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

        func lineEnd(from k: Int) -> Int {
            var j = k
            while j < chars.count, chars[j] != 0x0A { j += 1 }
            return j
        }

        mutating func run() {
            let n = chars.count
            while i < n {
                let c = chars[i]
                if c == 0x0A { i += 1; lineStart = true; continue }
                if c == 0x20 || c == 0x09 { i += 1; continue }
                let atLineStart = lineStart
                lineStart = false

                // Comments
                if let comment = language.lineComments.first(where: { matches($0, at: i) }),
                   !(comment == "#" && language.mode == .shell && i > 0 && chars[i - 1] == 0x24) {
                    let end = lineEnd(from: i)
                    add(i, end, .comment)
                    i = end
                    continue
                }
                if let (open, close) = language.blockComments.first(where: { matches($0.0, at: i) }) {
                    var j = i + open.utf16.count
                    while j < n, !matches(close, at: j) { j += 1 }
                    j = min(n, j + close.utf16.count)
                    add(i, j, .comment)
                    i = j
                    continue
                }
                if language.preprocessor, atLineStart, c == 0x23 /* # */ {
                    let end = lineEnd(from: i)
                    add(i, end, .preprocessor)
                    i = end
                    continue
                }
                // Strings
                if let q = language.multilineQuotes.first(where: { matches($0, at: i) }) {
                    let start = i
                    var j = i + q.utf16.count
                    while j < n, !matches(q, at: j) {
                        if chars[j] == 0x5C { j += 1 }
                        j += 1
                    }
                    i = min(n, j + q.utf16.count)
                    add(start, i, .string)
                    continue
                }
                if let q = language.quotes.first(where: { matches($0, at: i) }) {
                    // A single quote after an identifier is an apostrophe / lifetime, not a string.
                    if q == "'", i > 0, isIdentifierPart(chars[i - 1]), language.mode != .sql { i += 1; continue }
                    let start = i
                    let quote = chars[i]
                    var j = i + 1
                    while j < n, chars[j] != quote, chars[j] != 0x0A {
                        if chars[j] == 0x5C, language.mode != .sql { j += 1 }
                        j += 1
                    }
                    i = min(n, j + 1)
                    var token = Token.string
                    if language.mode == .json || language.mode == .yaml || language.mode == .toml {
                        var k = i
                        while k < n, chars[k] == 0x20 || chars[k] == 0x09 { k += 1 }
                        if k < n, chars[k] == 0x3A || (language.mode == .toml && chars[k] == 0x3D) { token = .attribute }
                    }
                    add(start, i, token)
                    continue
                }
                // Numbers
                if isDigit(c) || (c == 0x2E && i + 1 < n && isDigit(chars[i + 1]) && (i == 0 || !isIdentifierPart(chars[i - 1]))) {
                    if i > 0, isIdentifierPart(chars[i - 1]) { i += 1; continue }
                    let start = i
                    var j = i + 1
                    while j < n {
                        let d = chars[j]
                        if isIdentifierPart(d) || d == 0x2E {
                            j += 1
                        } else if (d == 0x2B || d == 0x2D), (chars[j - 1] | 0x20) == 0x65, !(matches("0x", at: start)) {
                            j += 1
                        } else {
                            break
                        }
                    }
                    if chars[j - 1] == 0x2E { j -= 1 }
                    add(start, j, .number)
                    i = j
                    continue
                }
                // Variables ($x, @x)
                if language.variablePrefixes.contains(c), i + 1 < n,
                   isIdentifierStart(chars[i + 1]) || chars[i + 1] == 0x7B || (language.mode == .shell && isDigit(chars[i + 1])) {
                    let start = i
                    var j = i + 1
                    if chars[j] == 0x7B {
                        while j < n, chars[j] != 0x7D, chars[j] != 0x0A { j += 1 }
                        j = min(n, j + 1)
                    } else {
                        while j < n, isIdentifierPart(chars[j]) && chars[j] != 0x2D || (language.mode == .css && chars[j] == 0x2D) { j += 1 }
                    }
                    add(start, j, .variable)
                    i = j
                    continue
                }
                // Annotations / attributes (@objc, #[derive])
                if let prefix = language.annotationPrefix, c == prefix, i + 1 < n,
                   isIdentifierStart(chars[i + 1]) || (prefix == 0x23 && chars[i + 1] == 0x5B) {
                    let start = i
                    var j = i + 1
                    if chars[j] == 0x5B {
                        while j < n, chars[j] != 0x5D, chars[j] != 0x0A { j += 1 }
                        j = min(n, j + 1)
                    } else {
                        while j < n, isIdentifierPart(chars[j]) { j += 1 }
                    }
                    add(start, j, .attribute)
                    i = j
                    continue
                }
                // CSS punctuation
                if language.mode == .css {
                    if c == 0x7B { braceDepth += 1 } else if c == 0x7D { braceDepth = max(0, braceDepth - 1) }
                    if c == 0x23, braceDepth > 0 { // #hex color
                        var j = i + 1
                        while j < n, isIdentifierPart(chars[j]) { j += 1 }
                        add(i, j, .number)
                        i = j
                        continue
                    }
                }
                // Identifiers
                if isIdentifierStart(c) || ((c == 0x40 || c == 0x2E || c == 0x21) && i + 1 < n && isIdentifierStart(chars[i + 1])
                                            && (language.identifierExtra.contains(c) || language.mode == .css)) {
                    let start = i
                    var j = i + 1
                    while j < n, isIdentifierPart(chars[j]) { j += 1 }
                    let word = String(utf16CodeUnits: Array(chars[start..<j]), count: j - start)
                    i = j
                    classify(word, start, j, atLineStart: atLineStart)
                    continue
                }
                i += 1
            }
        }

        mutating func classify(_ word: String, _ start: Int, _ end: Int, atLineStart: Bool) {
            let key = language.caseInsensitive ? word.lowercased() : word
            var k = end
            while k < chars.count, chars[k] == 0x20 || chars[k] == 0x09 { k += 1 }
            let next: UInt16 = k < chars.count ? chars[k] : 0

            switch language.mode {
            case .yaml:
                if atLineStart || next == 0x3A {
                    if next == 0x3A { add(start, end, .attribute); return }
                }
                if language.literals.contains(key) { add(start, end, .literal) }
                return
            case .toml:
                if next == 0x3D || (atLineStart && next == 0x3D) { add(start, end, .attribute); return }
                if language.literals.contains(key) { add(start, end, .literal) }
                return
            case .json:
                if language.literals.contains(key) { add(start, end, .literal) }
                return
            case .css:
                if language.keywords.contains(key) { add(start, end, .keyword); return }
                if braceDepth > 0 {
                    if next == 0x3A { add(start, end, .attribute) }
                } else if word.hasPrefix(".") || word.hasPrefix("#") {
                    add(start, end, .type)
                } else {
                    add(start, end, .tag)
                }
                return
            case .shell:
                if language.keywords.contains(key) { add(start, end, .keyword); return }
                if language.types.contains(key), atLineStart || isCommandPosition(start) { add(start, end, .function); return }
                if atLineStart, next == 0x3D { add(start, end, .variable); return }
                return
            default:
                break
            }
            if language.keywords.contains(key) {
                add(start, end, .keyword)
            } else if language.literals.contains(key) {
                add(start, end, .literal)
            } else if language.types.contains(key) {
                add(start, end, .type)
            } else if next == 0x28 /* ( */ {
                add(start, end, .function)
            } else if language.capitalizedTypes, let first = word.unicodeScalars.first,
                      CharacterSet.uppercaseLetters.contains(first), word.count > 1 {
                add(start, end, .type)
            }
        }

        /// True if the word at `start` begins a shell command (after `|`, `;`, `&&`, `$(`).
        func isCommandPosition(_ start: Int) -> Bool {
            var k = start - 1
            while k >= 0, chars[k] == 0x20 || chars[k] == 0x09 { k -= 1 }
            guard k >= 0 else { return true }
            let c = chars[k]
            return c == 0x7C || c == 0x3B || c == 0x26 || c == 0x28 || c == 0x0A || c == 0x60 || c == 0x24
        }
    }

    // MARK: - Diff and markup

    private static func diff(_ chars: [UInt16]) -> [(NSRange, Token)] {
        var tokens: [(NSRange, Token)] = []
        var start = 0
        let n = chars.count
        while start < n {
            var end = start
            while end < n, chars[end] != 0x0A { end += 1 }
            if end > start {
                let c = chars[start]
                let range = NSRange(location: start, length: end - start)
                let isHeader = (end - start >= 3) && ((c == 0x2B && chars[start + 1] == 0x2B && chars[start + 2] == 0x2B)
                                                      || (c == 0x2D && chars[start + 1] == 0x2D && chars[start + 2] == 0x2D))
                if isHeader { tokens.append((range, .meta)) }
                else if c == 0x2B { tokens.append((range, .inserted)) }
                else if c == 0x2D { tokens.append((range, .deleted)) }
                else if c == 0x40 { tokens.append((range, .meta)) }
                else if c == 0x21 || (end - start >= 4 && String(utf16CodeUnits: Array(chars[start..<(start + 4)]), count: 4) == "diff") {
                    tokens.append((range, .comment))
                }
            }
            start = end + 1
        }
        return tokens
    }

    private static func markup(_ chars: [UInt16]) -> [(NSRange, Token)] {
        var tokens: [(NSRange, Token)] = []
        let n = chars.count
        var i = 0
        func has(_ s: String, _ k: Int) -> Bool {
            var j = k
            for u in s.utf16 { guard j < n, chars[j] == u else { return false }; j += 1 }
            return true
        }
        while i < n {
            let c = chars[i]
            if c == 0x3C { // <
                if has("<!--", i) {
                    var j = i + 4
                    while j < n, !has("-->", j) { j += 1 }
                    j = min(n, j + 3)
                    tokens.append((NSRange(location: i, length: j - i), .comment))
                    i = j
                    continue
                }
                if has("<![CDATA[", i) {
                    var j = i + 9
                    while j < n, !has("]]>", j) { j += 1 }
                    j = min(n, j + 3)
                    tokens.append((NSRange(location: i, length: j - i), .string))
                    i = j
                    continue
                }
                // Tag name
                var j = i + 1
                if j < n, chars[j] == 0x2F || chars[j] == 0x21 || chars[j] == 0x3F { j += 1 }
                let nameStart = j
                while j < n, chars[j] > 0x20, chars[j] != 0x3E, chars[j] != 0x2F { j += 1 }
                guard j > nameStart else { i += 1; continue }
                tokens.append((NSRange(location: i, length: j - i), .tag))
                // Attributes until '>'
                while j < n, chars[j] != 0x3E {
                    let a = chars[j]
                    if a == 0x22 || a == 0x27 {
                        let s = j
                        j += 1
                        while j < n, chars[j] != a { j += 1 }
                        j = min(n, j + 1)
                        tokens.append((NSRange(location: s, length: j - s), .string))
                    } else if a > 0x20, a != 0x3D, a != 0x2F, a != 0x3F {
                        let s = j
                        while j < n, chars[j] > 0x20, chars[j] != 0x3D, chars[j] != 0x3E, chars[j] != 0x2F { j += 1 }
                        tokens.append((NSRange(location: s, length: j - s), .attribute))
                    } else {
                        j += 1
                    }
                }
                if j < n {
                    let closeStart = j > 0 && (chars[j - 1] == 0x2F || chars[j - 1] == 0x3F) ? j - 1 : j
                    tokens.append((NSRange(location: closeStart, length: j + 1 - closeStart), .tag))
                    j += 1
                }
                i = j
                continue
            }
            if c == 0x26 { // &entity;
                var j = i + 1
                while j < n, j - i < 32, chars[j] != 0x3B, chars[j] > 0x20, chars[j] != 0x3C { j += 1 }
                if j < n, chars[j] == 0x3B {
                    tokens.append((NSRange(location: i, length: j + 1 - i), .number))
                    i = j + 1
                    continue
                }
            }
            i += 1
        }
        return tokens
    }
}
