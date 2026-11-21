import Foundation

public struct SchedulingExtractInput: Sendable, Hashable {
    public var messageKey: String
    public var threadKey: String?
    public var subject: String
    public var from: String
    public var text: String
    public var sentAt: Date
    public var accountKey: String?

    public init(messageKey: String, threadKey: String? = nil, subject: String, from: String, text: String, sentAt: Date,
                accountKey: String? = nil) {
        self.messageKey = messageKey
        self.threadKey = threadKey
        self.subject = subject
        self.from = from
        self.text = text
        self.sentAt = sentAt
        self.accountKey = accountKey
    }
}

public struct SchedulingExtractedTime: Sendable, Hashable, Codable {
    public var day: String
    public var start: String
    public var end: String
    public var zone: String

    public init(day: String, start: String = "", end: String = "", zone: String = "") {
        self.day = day
        self.start = start
        self.end = end
        self.zone = zone
    }
}

public struct SchedulingDraftInput: Sendable, Hashable {
    public var thread: AIThreadInput
    public var instruction: String
    public var timeLines: [String]
    public var bookingLink: String?

    public init(thread: AIThreadInput, instruction: String, timeLines: [String], bookingLink: String? = nil) {
        self.thread = thread
        self.instruction = instruction
        self.timeLines = timeLines
        self.bookingLink = bookingLink
    }
}

public struct SchedulingDraftResult: Sendable, Hashable {
    public var body: String
    public var providerID: AIProviderID?
    public var suspicious: Bool

    public init(body: String, providerID: AIProviderID? = nil, suspicious: Bool = false) {
        self.body = body
        self.providerID = providerID
        self.suspicious = suspicious
    }
}

extension AIPolicy {
    public static let reservedSchedulingExtractTokens = 160
    public static let reservedSchedulingReplyTokens = 320
    public static let schedulingMaxTimes = 4
    public static let schedulingWordCharacters = 30
    public static let schedulingMessageCharacters = 4_000
    public static let schedulingContextMessages = 2
    public static let schedulingContextCharacters = 1_000
    public static let schedulingReplyCharacters = 1_500
}

extension OutputGuard {
    public static let schedulingExtractSchema: JSONSchema = .object(
        properties: [
            "times": .array(items: .object(properties: [
                "day": .string(maxLength: AIPolicy.schedulingWordCharacters),
                "start": .string(maxLength: AIPolicy.schedulingWordCharacters),
                "end": .string(maxLength: AIPolicy.schedulingWordCharacters),
                "zone": .string(maxLength: AIPolicy.schedulingWordCharacters),
            ], required: ["day"]), maxItems: AIPolicy.schedulingMaxTimes),
        ],
        required: ["times"])

    public static func schedulingTimes(from data: Data) throws -> [SchedulingExtractedTime] {
        let value: JSONValue
        do { value = try JSONValue.parse(data) } catch { throw AIError.invalidOutput("not JSON") }
        let errors = schedulingExtractSchema.validate(value)
        guard errors.isEmpty else { throw AIError.invalidOutput(errors.prefix(3).joined(separator: "; ")) }
        guard case .array(let items)? = value["times"] else { throw AIError.invalidOutput("times") }
        func word(_ item: JSONValue, _ key: String) -> String {
            let text = (item[key]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " || $0 == ":" }) ? text : ""
        }
        return items.compactMap { item in
            let day = word(item, "day")
            guard !day.isEmpty else { return nil }
            return SchedulingExtractedTime(day: day, start: word(item, "start"), end: word(item, "end"),
                                           zone: word(item, "zone"))
        }
    }
}

extension DefaultAIFeatures {
    public func extractSchedulingTimes(_ input: SchedulingExtractInput) async throws -> [SchedulingExtractedTime] {
        let text = input.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let engine = try await resolveModel(.scheduling, trigger: .user, accountKeys: [input.accountKey],
                                            threadKey: input.threadKey)
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        let output = OutputSpec.json(schema: OutputGuard.schedulingExtractSchema,
                                     maxTokens: AIPolicy.reservedSchedulingExtractTokens)
        let parts = [
            UntrustedPart(kind: .subject, id: input.threadKey ?? input.messageKey,
                          text: String(input.subject.prefix(AIPolicy.subjectCharacterCap))),
            UntrustedPart(kind: .sender, id: input.messageKey, text: String(input.from.prefix(AIPolicy.senderCharacterCap))),
            UntrustedPart(kind: .emailBody, id: input.messageKey,
                          text: Self.followUpCapped(text, AIPolicy.schedulingMessageCharacters), date: input.sentAt),
        ]
        return try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            let prepared = try await prepare(.schedulingExtract, engine: engine, nonce: nonce,
                                             trusted: [TrustedPart(kind: .today, text: today())], untrusted: parts,
                                             output: output, shrink: shrink)
            let used = try await requireFits(prepared, engine: engine)
            let (times, _, raw) = try await structuredAnswer(prepared, engine: engine, untrustedTokens: used) {
                try OutputGuard.schedulingTimes(from: $0)
            }
            return OutputGuard.isSuspicious(raw, nonce: nonce) ? [] : times
        }
    }

    public func draftSchedulingReply(_ input: SchedulingDraftInput) async throws -> SchedulingDraftResult {
        let engine = try await resolveModel(.scheduling, trigger: .user, accountKeys: [input.thread.accountKey],
                                            threadKey: input.thread.threadKey)
        guard engine.capabilities.dataLocation == .onDevice else { throw AIError.unavailable(.onDeviceOnly) }
        guard let answered = input.thread.messages.last else { throw AIError.invalidOutput("no message") }
        let output = OutputSpec.text(maxTokens: AIPolicy.reservedSchedulingReplyTokens)
        var instruction = input.instruction
        if let link = input.bookingLink, !link.isEmpty {
            guard let line = try? prompts.instruction(.schedulingBookingLink, values: ["link": link]) else {
                throw AIError.providerFailed("prompt \(PromptName.schedulingBookingLink.rawValue) unavailable")
            }
            instruction += "\n" + line
        }
        let trusted = [TrustedPart(kind: .userInstruction,
                                   text: String(instruction.prefix(AIPolicy.userInstructionCharacterCap)))]
        let earlier = input.thread.messages.dropLast().suffix(AIPolicy.schedulingContextMessages).flatMap { message in
            [senderPart(message), bodyPart(message, text: Self.followUpCapped(message.bodyText,
                                                                               AIPolicy.schedulingContextCharacters))]
        }
        let latest = [senderPart(answered),
                      bodyPart(answered, text: Self.followUpCapped(answered.bodyText, AIPolicy.schedulingMessageCharacters))]
        let style = Self.styleParts(input.thread.styleExamples, dataLocation: engine.capabilities.dataLocation)
        return try await withOverflowRetry { shrink in
            let nonce = makeNonce()
            var prepared = try await prepare(.schedulingReply, engine: engine, nonce: nonce, trusted: trusted,
                                             untrusted: [subjectPart(input.thread)] + earlier + latest, output: output,
                                             shrink: shrink)
            var kept = earlier
            while !kept.isEmpty, await engine.tokens(of: prepared.request.untrusted, nonce: nonce) > prepared.budget {
                kept.removeFirst(min(2, kept.count))
                prepared.request.untrusted = [subjectPart(input.thread)] + kept + latest
            }
            for example in style {
                let fits = await engine.tokens(of: prepared.request.untrusted + [example], nonce: nonce) <= prepared.budget
                if fits { prepared.request.untrusted.append(example) }
            }
            let used = try await requireFits(prepared, engine: engine)
            var capper = StreamCapper(maxTokens: output.maxTokens)
            let outcome = try await run(prepared, engine: engine, untrustedTokens: used) { delta in
                _ = capper.accept(delta)
                return !capper.truncated
            }
            let body = String(PromptScaffoldingFilter.strip(outcome.text, nonce: nonce)
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(AIPolicy.schedulingReplyCharacters))
            return SchedulingDraftResult(body: body, providerID: engine.provider.id,
                                         suspicious: OutputGuard.isSuspicious(outcome.text, nonce: nonce))
        }
    }
}

extension AIFeatures {
    public func extractSchedulingTimes(_ input: SchedulingExtractInput) async throws -> [SchedulingExtractedTime] {
        throw AIError.unavailable(.disabledBySettings)
    }

    public func draftSchedulingReply(_ input: SchedulingDraftInput) async throws -> SchedulingDraftResult {
        throw AIError.unavailable(.disabledBySettings)
    }
}
