import Foundation

public enum ReaderCSS {
    public enum ColorScheme: String, Sendable {
        case light, dark
        case lightDark = "light dark"
    }

    public static func stylesheet(for theme: ResolvedTheme, colorScheme: ColorScheme? = nil) -> String {
        stylesheet(tokens: theme.tokens, colorScheme: colorScheme ?? (theme.appearance == .dark ? .dark : .light),
                   underlineLinks: theme.accentID == "graphite")
    }

    public static func variables(tokens: ThemeTokens) -> [(name: String, value: String)] {
        var vars: [(String, String)] = []
        for (variable, key) in ReaderCSSVariables.tokens {
            guard let value = tokens.value(forKey: key) else { continue }
            switch value {
            case .color(let color): vars.append((variable, color.css))
            case .number(let n): vars.append((variable, px(n)))
            default: continue
            }
        }
        let reader = tokens.typeReader
        let mono = tokens.typeMono
        vars.append(("--oh-bg", "transparent"))
        vars.append(("--oh-font", fontStack(reader.family, role: .reader)))
        vars.append(("--oh-size", px(reader.size)))
        vars.append(("--oh-lh", px(reader.lineHeight)))
        vars.append(("--oh-tracking", reader.effectiveTracking == 0 ? "normal" : px(reader.effectiveTracking)))
        vars.append(("--oh-mono-font", fontStack(mono.family, role: .mono)))
        vars.append(("--oh-mono-size", px(mono.size)))
        vars.append(("--oh-mono-lh", px(mono.lineHeight)))
        vars.append(("--oh-max-image-width", percent(tokens.readerMaxImageWidth)))
        return vars
    }

    public static func stylesheet(tokens t: ThemeTokens, colorScheme: ColorScheme, underlineLinks: Bool = false) -> String {
        let root = (["color-scheme: \(colorScheme.rawValue)"] + variables(tokens: t).map { "\($0.name): \($0.value)" })
            .map { "  \($0);" }.joined(separator: "\n")
        let quoteBar = px(t.readerQuoteBarWidth)
        return """
        :root {
        \(root)
        }
        html, body { margin: 0; padding: 0; background: var(--oh-bg); }
        body { font: var(--oh-size)/var(--oh-lh) var(--oh-font); letter-spacing: var(--oh-tracking); color: var(--oh-text);
               overflow-wrap: anywhere; -webkit-text-size-adjust: 100%; }
        a { color: var(--oh-link);\(underlineLinks ? " text-decoration: underline;" : "") }
        img { max-width: var(--oh-max-image-width); height: auto; }
        blockquote[type=cite], .gmail_quote blockquote {
          margin: 0 0 0 \(quoteBar); padding-left: \(px(t.space4)); border-left: \(quoteBar) solid var(--oh-quote);
          color: var(--oh-text-secondary); }
        details.oh-quoted > summary { list-style: none; cursor: default; display: inline-block;
          width: \(px(t.space7)); height: \(px(t.space5)); border-radius: 999px; background: var(--oh-sunken); }
        details.oh-quoted > summary:hover, details.oh-quoted > summary:focus-visible {
          background: color-mix(in srgb, var(--oh-text) 12%, var(--oh-sunken)); }
        mark.oh-hit { background: var(--oh-mark); color: inherit; border-radius: var(--oh-radius-xs); padding: 0 \(px(t.space1 / 2)); }
        pre, code { font: var(--oh-mono-size)/var(--oh-mono-lh) var(--oh-mono-font); }
        table { max-width: 100%; }
        .oh-card { background: var(--oh-card-bg); border: \(px(t.borderWidthHairline)) solid var(--oh-card-border);
          border-radius: var(--oh-card-radius); }
        """
    }

    public static func replaceScript(css: String) -> String {
        let literal = (try? JSONEncoder().encode(css)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        return "(function(){var s=document.getElementById(\"oh-base\");if(s){s.textContent=\(literal);}})();"
    }

    static func px(_ value: Double) -> String { value == 0 ? "0" : "\(ThemeColor.shortNumber(value))px" }

    static func percent(_ value: Double) -> String { "\(ThemeColor.shortNumber(value))%" }

    public static func fontStack(_ family: FontFamily, role: FontRole) -> String {
        let system = role == .mono ? "ui-monospace, \"SF Mono\", monospace" : "-apple-system, \"SF Pro Text\", system-ui, sans-serif"
        switch family {
        case .system: return system
        case .systemSerif: return "ui-serif, \"New York\", serif"
        case .systemRounded: return "ui-rounded, \"SF Pro Rounded\", -apple-system, system-ui, sans-serif"
        case .systemMono: return "ui-monospace, \"SF Mono\", monospace"
        case .named(let name): return cssString(name) + ", " + system
        }
    }

    static func cssString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            let ok = scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || scalar == " " || scalar == "-")
            out += ok ? String(scalar) : String(format: "\\%06X ", scalar.value)
        }
        return out + "\""
    }
}
