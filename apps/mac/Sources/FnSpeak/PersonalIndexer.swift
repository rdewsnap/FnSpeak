import Contacts
import EventKit
import Foundation

/// Feeds personal vocabulary into the engine: contact names, calendar titles
/// and attendees, and project names. Everything stays on this Mac.
final class PersonalIndexer {
    private let engine: EngineController
    private let prefs = Preferences.shared
    private let contacts = CNContactStore()
    private let events = EKEventStore()

    init(engine: EngineController) {
        self.engine = engine
    }

    func indexAll() {
        indexProjects()
        if prefs.indexContacts { indexContacts() }
        if prefs.indexCalendar { indexCalendar() }
    }

    func indexProjects() {
        let folder = prefs.projectsFolder
        guard FileManager.default.fileExists(atPath: folder) else { return }
        DispatchQueue.global(qos: .utility).async {
            let terms = (try? scanProjects(root: folder)) ?? []
            self.engine.addTerms(terms, source: .project)
        }
    }

    func indexContacts() {
        contacts.requestAccess(for: .contacts) { granted, _ in
            guard granted else { return }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            var names = Set<String>()
            try? self.contacts.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for name in [full, contact.givenName, contact.familyName, contact.nickname, contact.organizationName] where name.count >= 3 {
                    names.insert(name)
                }
            }
            self.engine.addTerms(Array(names), source: .contact)
        }
    }

    func indexCalendar() {
        events.requestFullAccessToEvents { granted, _ in
            guard granted else { return }
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
            let end = Calendar.current.date(byAdding: .day, value: 30, to: now)!
            let predicate = self.events.predicateForEvents(withStart: start, end: end, calendars: nil)
            var terms = Set<String>()
            for event in self.events.events(matching: predicate) {
                // Short titles are usually names ("Kinju standup"); long ones are sentences.
                if let title = event.title, title.split(separator: " ").count <= 4 { terms.insert(title) }
                for attendee in event.attendees ?? [] {
                    if let name = attendee.name, name.contains(" "), !name.contains("@") { terms.insert(name) }
                }
            }
            self.engine.addTerms(Array(terms), source: .calendar)
        }
    }
}
