import Foundation
import MailFakes
import MailModel
import OpenHumanCore
import Testing
@testable import MailFeatures

@MainActor
@Suite struct SnippetRecipientsFilesTests {
    private let temp = TemporaryDirectory("snippet-v2", isDirectory: true)

    private func tempFile(_ name: String, bytes: Int = 64) throws -> URL {
        let dir = temp.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    @Test func insertingASnippetOnlyAddsRecipientsOnce() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let dana = EmailAddress(name: "Dana", email: "dana@example.com")
        session.to.setTokens([dana])
        let snippet = SnippetInfo(name: "Intro", bodyHTML: "<p>Hello</p>",
                                  to: [EmailAddress(email: "DANA@example.com"), EmailAddress(name: "Sam", email: "sam@example.com")],
                                  cc: [EmailAddress(email: "lee@example.com"), EmailAddress(email: "sam@example.com")],
                                  bcc: [EmailAddress(email: "dana@example.com")])
        session.didInsertSnippet(session.insertion(snippet, range: nil), unresolved: [])
        #expect(session.to.tokens.map(\.email) == ["dana@example.com", "sam@example.com"], "Dana kept as she was, Sam added")
        #expect(session.to.tokens.first?.name == "Dana")
        #expect(session.cc.tokens.map(\.email) == ["lee@example.com"], "Sam is already on the message")
        #expect(session.bcc.tokens.isEmpty)
        #expect(session.showsCc && !session.showsBcc)
        session.didInsertSnippet(session.insertion(snippet, range: nil), unresolved: [])
        #expect(session.allRecipients.count == 3)
    }

    @Test func insertingASnippetAttachesItsFilesOnce() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let file = try tempFile("terms.pdf", bytes: 2048)
        let snippet = SnippetInfo(name: "Terms", bodyHTML: "<p>Attached.</p>", attachments: [
            SnippetAttachmentInfo(contentHash: String(repeating: "a", count: 64), filename: "terms.pdf",
                                  mimeType: "application/pdf", size: 2048, fileURL: file),
        ])
        session.didInsertSnippet(session.insertion(snippet, range: nil), unresolved: [])
        #expect(session.attachments.map(\.filename) == ["terms.pdf"])
        #expect(session.attachments.first?.size == 2048 && session.attachments.first?.localPath != nil)
        session.didInsertSnippet(session.insertion(snippet, range: nil), unresolved: [])
        #expect(session.attachments.count == 1, "not attached twice")
        session.removeAttachment(try #require(session.attachments.first))
        #expect(session.attachments.isEmpty)
    }

    @Test func aSnippetFileWithoutAStoredCopySaysSo() async throws {
        let f = ComposeFixture()
        await f.loaded()
        let session = try #require(f.compose.openNew(placement: .modal))
        let snippet = SnippetInfo(name: "Gone", bodyHTML: "<p>x</p>", attachments: [
            SnippetAttachmentInfo(contentHash: String(repeating: "b", count: 64), filename: "gone.txt", mimeType: "text/plain", size: 3),
        ])
        #expect(session.applySnippetRecipientsAndFiles(snippet) == 1)
        #expect(session.attachments.isEmpty)
        #expect(session.notice?.text.contains("isn't on this Mac") == true)
    }

    private func editor(_ f: SettingsFixture) async -> SnippetSettingsModel {
        let model = SnippetSettingsModel(environment: f.env)
        model.start()
        return model
    }

    @Test func theEditorSavesRecipientsAndFiles() async throws {
        let f = SettingsFixture()
        let model = await editor(f)
        model.beginNew()
        model.draft?.name = "Contract"
        model.draft?.body = "Please find the contract attached."
        model.draft?.to = "Legal <legal@example.com>, legal@example.com"
        model.draft?.cc = "boss@example.com"
        let file = try tempFile("contract.txt", bytes: 300)
        await model.addFiles([file])
        #expect(model.draft?.attachments.map(\.filename) == ["contract.txt"])
        #expect(model.recipientProblem == nil && model.canSave)
        await model.save()
        let saved = try #require(try await f.snippets().first { $0.name == "Contract" })
        #expect(saved.to == [EmailAddress(name: "Legal", email: "legal@example.com")], "once each")
        #expect(saved.cc.map(\.email) == ["boss@example.com"] && saved.bcc.isEmpty)
        #expect(saved.attachments.map(\.size) == [300])
        model.beginEdit(saved)
        #expect(model.draft?.to == "Legal <legal@example.com>" && model.draft?.attachments.count == 1)
    }

    @Test func theEditorRefusesBadAddressesAndOversizedFiles() async throws {
        let f = SettingsFixture()
        let model = await editor(f)
        model.beginNew()
        model.draft?.name = "N"
        model.draft?.body = "B"
        model.draft?.bcc = "not-an-address"
        #expect(model.recipientProblem == "Check the Bcc line: not-an-address isn't a valid address.")
        #expect(!model.canSave)
        model.draft?.bcc = ""
        let big = try tempFile("big.bin", bytes: SnippetAttachmentRules.maxFileBytes + 1)
        await model.addFiles([big])
        #expect(model.draft?.attachments.isEmpty == true)
        #expect(model.errorMessage?.contains("over the 10 MB limit for a snippet file.") == true)
        #expect(model.canSave)
    }

    @Test func aV2FileCarriesRecipientsAndFilesAndImportsThem() async throws {
        let a = SettingsFixture()
        let stored = try await a.store.storeSnippetAttachment(try tempFile("guide.txt", bytes: 120), mimeType: "text/plain")
        _ = try await a.store.upsertSnippet(SnippetInfo(name: "Onboarding", bodyHTML: "<p>Welcome</p>",
                                                        cc: [EmailAddress(email: "team@example.com")], attachments: [stored]))
        let file = try await SnippetTransferModel(environment: a.env).export()
        let bundle = try JSONDecoder().decode(SnippetBundle.self, from: file)
        #expect(bundle.version == 2)
        let entry = try #require(bundle.snippets.first { $0.name == "Onboarding" })
        #expect(entry.cc?.map(\.email) == ["team@example.com"] && entry.files?.first?.data.count == 120)

        let b = SettingsFixture()
        let model = SnippetTransferModel(environment: b.env)
        let preview = try await model.prepareImport(file)
        #expect(preview.withRecipients == 1 && preview.files == 1 && preview.filesDropped == 0)
        #expect(preview.detail?.contains("adds recipients") == true)
        await model.applyImport()
        let imported = try #require(try await b.snippets().first { $0.name == "Onboarding" })
        #expect(imported.cc.map(\.email) == ["team@example.com"])
        #expect(imported.attachments.map(\.size) == [120] && imported.attachments.first?.fileURL != nil)
    }

    @Test func aV1FileKeepsTheReplacedSnippetsRecipientsAndFiles() async throws {
        let b = SettingsFixture()
        let stored = try await b.store.storeSnippetAttachment(try tempFile("keep.txt"), mimeType: "text/plain")
        _ = try await b.store.upsertSnippet(SnippetInfo(name: "Sign-off", bodyHTML: "Old", to: [EmailAddress(email: "x@example.com")],
                                                        attachments: [stored]))
        let v1 = SnippetBundle(snippets: [SnippetBundle.Snippet(name: "Sign-off", shortcut: nil, subject: nil, bodyHTML: "New",
                                                                 variables: [])])
        #expect(v1.version == 1, "no v2 content: written as version 1")
        let model = SnippetTransferModel(environment: b.env)
        _ = try await model.prepareImport(try JSONEncoder().encode(v1))
        await model.applyImport()
        let replaced = try #require(try await b.snippets().first { $0.name == "Sign-off" })
        #expect(replaced.bodyHTML == "New")
        #expect(replaced.to.map(\.email) == ["x@example.com"] && replaced.attachments == [stored])
    }

    @Test func oversizedOrDamagedFilesInAFileAreLeftOut() {
        let ok = SnippetBundle.File(filename: "a.txt", mimeType: "text/plain", size: 3, data: Data("abc".utf8))
        let lying = SnippetBundle.File(filename: "b.txt", mimeType: "text/plain", size: 99, data: Data("abc".utf8))
        let huge = SnippetBundle.File(filename: "c.bin", mimeType: "application/octet-stream",
                                      size: SnippetAttachmentRules.maxFileBytes + 1,
                                      data: Data(count: SnippetAttachmentRules.maxFileBytes + 1))
        #expect(SnippetTransferModel.acceptedFiles([ok, lying, huge]) == [ok])
        #expect(SnippetTransferModel.validRecipients([EmailAddress(email: "bad"), EmailAddress(email: "a@example.com"),
                                                      EmailAddress(email: "A@example.com")]).map(\.email) == ["a@example.com"])
    }
}
