import Foundation

/// Domains that many unrelated people send mail from, so a rule for the whole domain reaches far beyond one sender.
///
/// Two kinds are listed:
/// - `mailboxProvider`: consumer and shared mailbox services (Gmail, Yahoo, Outlook, iCloud, regional ISPs, privacy
///   providers). Anyone can have an address there.
/// - `sharedSender`: sending infrastructure and platforms that relay mail for many different people or companies
///   (bulk-mail services, newsletter hosts, collaboration and social sites).
///
/// A listed entry also covers every subdomain of it (`mail.yahoo.co.uk` is covered by `yahoo.co.uk`, and
/// `docs.google.com` by `google.com`). Brands in `regionalBrands` are covered under any country domain
/// (`yahoo.fr`, `hotmail.co.uk`, `outlook.com.au`, `gmx.at`). To add a domain, put it in the matching list below.
public enum CommonMailDomains {
    public enum Kind: String, Sendable, Hashable {
        case mailboxProvider
        case sharedSender
    }

    public static let mailboxProviders: Set<String> = [
        // Google
        "gmail.com", "googlemail.com",
        // Yahoo and AOL (regional Yahoo and AOL domains are in regionalBrands)
        "yahoo.com", "ymail.com", "rocketmail.com", "myyahoo.com", "aol.com", "aim.com", "love.com", "games.com",
        "wow.com", "ygm.com",
        // Microsoft (regional Outlook, Hotmail and Live domains are in regionalBrands)
        "outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com", "windowslive.com",
        // Apple
        "icloud.com", "me.com", "mac.com", "privaterelay.appleid.com",
        // Hey
        "hey.com",
        // Proton
        "proton.me", "protonmail.com", "protonmail.ch", "pm.me", "passmail.net", "passmail.com",
        // Fastmail
        "fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.us", "fastmail.to",
        "messagingengine.com", "sent.com",
        // GMX and Mail.com
        "gmx.com", "gmx.net", "gmx.de", "gmx.at", "gmx.ch", "gmx.us", "gmx.co.uk", "gmx.fr", "mail.com", "email.com",
        "usa.com", "post.com", "europe.com", "myself.com", "consultant.com", "engineer.com", "techie.com",
        "writeme.com", "iname.com", "dr.com", "cheerful.com",
        // Zoho
        "zoho.com", "zohomail.com", "zoho.eu", "zohomail.eu", "zoho.in", "zohomail.in", "zoho.com.au",
        // Yandex, Mail.ru, Rambler
        "yandex.ru", "yandex.com", "yandex.ua", "yandex.by", "yandex.kz", "yandex.com.tr", "ya.ru", "narod.ru",
        "mail.ru", "inbox.ru", "list.ru", "bk.ru", "internet.ru", "mail.ua", "rambler.ru",
        // China
        "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net", "188.com", "sina.com", "sina.cn", "sina.com.cn",
        "sohu.com", "aliyun.com", "139.com", "189.cn", "263.net", "tom.com",
        // Korea
        "naver.com", "daum.net", "hanmail.net", "kakao.com", "nate.com",
        // Japan
        "docomo.ne.jp", "ezweb.ne.jp", "au.com", "softbank.ne.jp", "i.softbank.jp", "nifty.com", "biglobe.ne.jp",
        "ocn.ne.jp",
        // Italy
        "libero.it", "virgilio.it", "tiscali.it", "alice.it", "tim.it", "email.it", "inwind.it", "iol.it",
        "fastwebnet.it",
        // Germany, Austria, Switzerland
        "web.de", "t-online.de", "freenet.de", "arcor.de", "online.de", "mail.de", "posteo.de", "posteo.net",
        "mailbox.org", "1und1.de", "chello.at", "aon.at", "bluewin.ch", "sunrise.ch",
        // France
        "orange.fr", "wanadoo.fr", "free.fr", "sfr.fr", "neuf.fr", "laposte.net", "bbox.fr", "numericable.fr",
        "aliceadsl.fr", "club-internet.fr",
        // Spain and Portugal
        "telefonica.net", "movistar.es", "terra.es", "sapo.pt",
        // Benelux
        "ziggo.nl", "kpnmail.nl", "planet.nl", "home.nl", "hetnet.nl", "xs4all.nl", "casema.nl", "chello.nl",
        "skynet.be", "telenet.be", "proximus.be",
        // Nordics
        "telia.com", "online.no", "bredband.net",
        // Poland and Czechia
        "wp.pl", "o2.pl", "onet.pl", "op.pl", "interia.pl", "gazeta.pl", "tlen.pl", "seznam.cz", "email.cz",
        "centrum.cz", "post.cz",
        // United Kingdom and Ireland
        "btinternet.com", "btopenworld.com", "bt.com", "sky.com", "virginmedia.com", "ntlworld.com",
        "blueyonder.co.uk", "talktalk.net", "tiscali.co.uk", "plus.com", "eircom.net",
        // United States
        "comcast.net", "xfinity.com", "verizon.net", "att.net", "sbcglobal.net", "bellsouth.net", "pacbell.net",
        "ameritech.net", "flash.net", "nvbell.net", "prodigy.net", "swbell.net", "wans.net", "snet.net", "cox.net",
        "charter.net", "spectrum.net", "twc.com", "rr.com", "roadrunner.com", "brighthouse.com", "earthlink.net",
        "mindspring.com", "juno.com", "netzero.net", "netzero.com", "optonline.net", "optimum.net", "frontier.com",
        "frontiernet.net", "windstream.net", "centurylink.net", "embarqmail.com", "q.com", "mediacombb.net",
        "suddenlink.net", "cableone.net", "wowway.com", "rcn.com",
        // Canada
        "shaw.ca", "rogers.com", "sympatico.ca", "bell.net", "telus.net", "videotron.ca", "cogeco.ca", "eastlink.ca",
        // Australia and New Zealand
        "bigpond.com", "bigpond.net.au", "telstra.com", "optusnet.com.au", "iinet.net.au", "tpg.com.au",
        "internode.on.net", "westnet.com.au", "xtra.co.nz",
        // Latin America
        "uol.com.br", "bol.com.br", "terra.com.br", "ig.com.br", "globo.com", "globomail.com", "prodigy.net.mx",
        // India, Israel, Turkey
        "rediffmail.com", "sify.com", "walla.co.il", "walla.com", "mynet.com",
        // Privacy and independent providers, and forwarding aliases
        "tutanota.com", "tutanota.de", "tutamail.com", "tuta.io", "tuta.com", "keemail.me", "runbox.com",
        "hushmail.com", "hush.com", "countermail.com", "startmail.com", "mailfence.com", "disroot.org", "riseup.net",
        "duck.com", "simplelogin.com", "simplelogin.co", "aleeas.com", "slmail.me", "anonaddy.com", "anonaddy.me",
        "addy.io", "mozmail.com", "33mail.com",
        // Older webmail
        "lycos.com", "excite.com", "inbox.com", "mail2world.com",
    ]

    public static let sharedSenders: Set<String> = [
        // Bulk-mail and transactional sending services
        "amazonses.com", "sendgrid.net", "sendgrid.com", "mailchimp.com", "mailchimpapp.net", "mcsv.net", "mcdlv.net",
        "rsgsv.net", "list-manage.com", "mandrillapp.com", "mailgun.org", "mailgun.net", "sparkpostmail.com",
        "mtasv.net", "postmarkapp.com", "sendinblue.com", "brevo.com", "constantcontact.com", "exacttarget.com",
        "hubspotemail.net", "klaviyomail.com", "convertkit-mail.com", "mailerlite.com", "mlsend.com", "aweber.com",
        "getresponse.com", "icontact.com", "emarsys.net", "createsend.com", "cmail19.com", "cmail20.com",
        "intercom-mail.com", "customeriomail.com", "mailjet.com", "sendpulse.com", "elasticemail.com",
        "socketlabs.com",
        // Newsletter and publishing platforms
        "substack.com", "beehiiv.com", "ghost.io", "buttondown.email", "medium.com", "patreon.com",
        // Google services that send for other people (Docs, Calendar, Groups, Forms)
        "google.com", "googlegroups.com", "youtube.com",
        // Code, work and collaboration tools
        "github.com", "gitlab.com", "bitbucket.org", "atlassian.net", "atlassian.com", "notion.so", "slack.com",
        "discord.com", "figma.com", "zoom.us", "calendly.com", "dropbox.com", "dropboxmail.com", "box.com",
        "docusign.net", "docusign.com", "teams.microsoft.com", "sharepointonline.com", "zendesk.com",
        "freshdesk.com", "helpscout.net", "typeform.com", "jotform.com", "groups.io",
        // Social, events and marketplaces that relay messages between members
        "linkedin.com", "facebookmail.com", "facebook.com", "instagram.com", "twitter.com", "x.com", "eventbrite.com",
        "meetup.com", "craigslist.org", "airbnb.com", "indeedemail.com",
    ]

    /// Brands whose domain under any country code (`.de`, `.co.uk`, `.com.br`) or `.com`, `.net`, `.org` is the same
    /// shared provider.
    public static let regionalBrands: Set<String> = [
        "yahoo", "hotmail", "outlook", "live", "windowslive", "aol", "gmx", "yandex", "zoho", "zohomail",
        "fastmail", "posteo", "tutanota",
    ]

    /// Second-level labels that country domains use before the country code (`co.uk`, `com.br`, `ne.jp`).
    static let countrySecondLevels: Set<String> = ["co", "com", "net", "org", "ne", "or"]
    static let genericTopLevels: Set<String> = ["com", "net", "org"]

    /// True when a rule for `domain` would reach many unrelated senders. Accepts a domain or an address, with any
    /// case, a leading `@` and trailing dots; subdomains and regional variants of a listed provider count.
    public static func isCommonMailDomain(_ domain: String) -> Bool {
        match(domain) != nil
    }

    /// The listed provider domain that covers `domain` (`yahoo.co.uk` for `mail.yahoo.co.uk`), or nil.
    public static func matchedEntry(_ domain: String) -> String? {
        match(domain)?.entry
    }

    public static func kind(of domain: String) -> Kind? {
        match(domain)?.kind
    }

    /// Lowercased host with no `@`, surrounding brackets, leading `*.` or trailing dots; nil when it is not a
    /// dotted host name.
    public static func normalizedHost(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>").union(.whitespaces))
        if text.hasPrefix("*.") { text.removeFirst(2) }
        while text.hasSuffix(".") { text.removeLast() }
        while text.hasPrefix(".") { text.removeFirst() }
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              !text.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "," || $0 == "<" || $0 == ">" })
        else { return nil }
        return text
    }

    static func match(_ raw: String) -> (entry: String, kind: Kind)? {
        guard let host = normalizedHost(raw) else { return nil }
        let labels = host.split(separator: ".").map(String.init)
        for start in 0..<(labels.count - 1) {
            let tail = Array(labels[start...])
            let suffix = tail.joined(separator: ".")
            if mailboxProviders.contains(suffix) { return (suffix, .mailboxProvider) }
            if sharedSenders.contains(suffix) { return (suffix, .sharedSender) }
            if isRegionalBrand(tail) { return (suffix, .mailboxProvider) }
        }
        return nil
    }

    static func isRegionalBrand(_ labels: [String]) -> Bool {
        guard let brand = labels.first, regionalBrands.contains(brand) else { return false }
        let rest = Array(labels.dropFirst())
        func isCountryCode(_ label: String) -> Bool { label.count == 2 && label.allSatisfy { ("a"..."z").contains($0) } }
        switch rest.count {
        case 1: return isCountryCode(rest[0]) || genericTopLevels.contains(rest[0])
        case 2: return countrySecondLevels.contains(rest[0]) && isCountryCode(rest[1])
        default: return false
        }
    }
}
