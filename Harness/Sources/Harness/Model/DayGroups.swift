import Foundation

/// The list's sections: Today, Yesterday, then dates, newest first.
public struct DayGroup: Equatable, Sendable {
    public let title: String
    public let day: Date
    public let recordings: [Recording]

    public static func group(_ recordings: [Recording], now: Date = Date(), calendar: Calendar = .current) -> [DayGroup] {
        let sorted = recordings.sorted { $0.createdAt > $1.createdAt }
        var groups: [DayGroup] = []
        var current: (day: Date, items: [Recording])?
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate("EEEE d MMMM")
        let thisYear = DateFormatter()
        thisYear.calendar = calendar
        thisYear.timeZone = calendar.timeZone
        thisYear.locale = Locale.current
        thisYear.setLocalizedDateFormatFromTemplate("EEEE d MMMM yyyy")
        func title(_ day: Date) -> String {
            if calendar.isDate(day, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
            return calendar.isDate(day, equalTo: now, toGranularity: .year) ? formatter.string(from: day) : thisYear.string(from: day)
        }
        for r in sorted {
            let day = calendar.startOfDay(for: r.createdAt)
            if let c = current, c.day == day {
                current = (day, c.items + [r])
            } else {
                if let c = current { groups.append(DayGroup(title: title(c.day), day: c.day, recordings: c.items)) }
                current = (day, [r])
            }
        }
        if let c = current { groups.append(DayGroup(title: title(c.day), day: c.day, recordings: c.items)) }
        return groups
    }

    /// The recordings whose text contains `query` (any case); all of them for an empty query.
    public static func filter(_ recordings: [Recording], query: String) -> [Recording] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return recordings }
        return recordings.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}
