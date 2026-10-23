import AppKit
import MailFeatures
import MailModel

extension ReaderViewController {
    func markDates(in view: ReaderWebView) {
        guard let sidebar = router?.environment.calendarSidebar else { return }
        let zone = sidebar.timeZone
        Task { [weak self, weak view] in
            guard let view, let text = await view.pageText(), !text.isEmpty else { return }
            let spans = await Task.detached(priority: .userInitiated) {
                CalendarDateMentions.spans(in: text, timeZone: zone)
            }.value
            guard !spans.isEmpty else { return }
            view.onDateClicked = { [weak self] index in
                guard spans.indices.contains(index) else { return }
                self?.openDate(spans[index].mention)
            }
            await view.underlineDates(spans.map(\.words))
        }
    }

    func markDates(in view: PlainTextMessageView) {
        guard let sidebar = router?.environment.calendarSidebar else { return }
        view.markDates(timeZone: sidebar.timeZone)
    }

    func openDate(_ index: Int, in view: PlainTextMessageView) {
        guard view.dateSpans.indices.contains(index) else { return }
        openDate(view.dateSpans[index].mention)
    }

    func openDate(_ mention: CalendarDateMention) {
        guard let model, let sidebar = router?.environment.calendarSidebar else { return }
        let thread = model.thread
        Task { await sidebar.reveal(mention, in: thread) }
    }
}
