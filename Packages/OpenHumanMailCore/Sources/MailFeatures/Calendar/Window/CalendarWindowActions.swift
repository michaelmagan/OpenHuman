import Foundation
import MailActions
import MailModel

@MainActor
enum CalendarWindowActions {
    static let ids: Set<ActionID> = [.calendarOpen, .calendarBackToMail, .calendarCycleView, .calendarClose,
                                     .calendarShowToday, .calendarPreviousPeriod, .calendarNextPeriod, .calendarShowDay,
                                     .calendarShowThreeDays, .calendarShowWeek, .calendarShowMonth, .calendarNewEvent,
                                     .calendarRefresh, .calendarRemoveEvent]

    static func availability(of id: ActionID, in context: ActionContext, environment: AppEnvironment) -> ActionAvailability {
        guard ids.contains(id), environment.calendarWindow != nil else { return .hidden }
        let isOpen = environment.calendarWindowIfStarted?.isOpen == true
        switch id {
        case .calendarOpen:
            return isOpen ? .hidden : .enabled
        case .calendarRemoveEvent:
            guard isOpen, let card = environment.calendarWindowIfStarted?.card, card.canRemove,
                  card.pendingMove == nil else { return .hidden }
            return .enabled
        case .calendarShowDay, .calendarShowThreeDays, .calendarShowWeek, .calendarShowMonth, .calendarNewEvent:
            return .enabled
        default:
            return isOpen ? .enabled : .hidden
        }
    }

    static func stepAside(for descriptor: ActionDescriptor, host: (any ActionHost)?) -> Bool {
        guard showsMail(descriptor), let router = host as? AppRouter,
              let window = router.environment.calendarWindowIfStarted, window.isOpen else { return false }
        window.stepAside()
        return true
    }

    static func showsMail(_ descriptor: ActionDescriptor) -> Bool {
        if descriptor.id.accountPosition != nil { return true }
        guard descriptor.category == .navigation else { return false }
        return ![ActionID.goSnippets, .saveSearch, .deleteSavedSearch].contains(descriptor.id)
    }

    static func perform(_ request: ActionRequest, environment: AppEnvironment) -> ActionPerformance {
        guard ids.contains(request.id), let window = environment.calendarWindow else { return .notHandled }
        let source = request.source
        switch request.id {
        case .calendarOpen:
            return .started(Task { await window.open(source == .keyboard ? .week : nil, source: source) })
        case .calendarBackToMail:
            return .started(Task { await window.close(source: source) })
        case .calendarCycleView:
            return .started(Task { await window.cycleView() })
        case .calendarClose:
            guard window.isOpen else { return .notHandled }
            return .started(Task { await window.escape() })
        case .calendarShowToday:
            return .started(Task { await window.goToToday() })
        case .calendarPreviousPeriod, .calendarNextPeriod:
            let delta = request.id == .calendarNextPeriod ? 1 : -1
            return .started(Task { await window.move(by: delta) })
        case .calendarShowDay, .calendarShowThreeDays, .calendarShowWeek, .calendarShowMonth:
            let kind: CalendarViewKind = switch request.id {
            case .calendarShowDay: .day
            case .calendarShowThreeDays: .threeDays
            case .calendarShowMonth: .month
            default: .week
            }
            return .started(Task {
                if window.isOpen { await window.setKind(kind) } else { await window.open(kind) }
            })
        case .calendarNewEvent:
            return .started(Task {
                if !window.isOpen { await window.open() }
                await window.newEvent()
            })
        case .calendarRefresh:
            return .started(Task { await window.refresh() })
        case .calendarRemoveEvent:
            guard window.isOpen, window.card?.canRemove == true, window.removeQuestion == nil else { return .notHandled }
            window.askToRemoveCardEvent()
            return .done
        default:
            return .notHandled
        }
    }
}
