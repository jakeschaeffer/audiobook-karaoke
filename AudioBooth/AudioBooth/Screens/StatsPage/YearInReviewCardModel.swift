import API
import Foundation

final class YearInReviewCardModel: YearInReviewCard.Model {
  private var hasFetchedStats = false

  init(listeningDays: [String: Double]) {
    let availableYears = Self.extractYearsFromDays(listeningDays)
    let defaultYear = Self.determineDefaultYear(from: listeningDays)

    super.init(
      isLoading: false,
      year: defaultYear,
      stats: .placeholder,
      availableYears: availableYears
    )
  }

  override func onExpanded() {
    guard !hasFetchedStats else { return }
    hasFetchedStats = true
    Task {
      isLoading = true
      await fetchYearStats()
    }
  }

  override func onYearChanged(_ newYear: Int) {
    year = newYear
    hasFetchedStats = false
    Task {
      isLoading = true
      stats = .placeholder
      await fetchYearStats()
      hasFetchedStats = true
    }
  }

  private func fetchYearStats() async {
    do {
      let yearStats = try await Audiobookshelf.shared.authentication.fetchYearStats(year: year)
      stats = processYearStats(yearStats)
      isLoading = false
    } catch {
      isLoading = false
    }
  }

  private func processYearStats(_ stats: YearStats) -> YearInReviewStats {
    let monthName: String
    if let month = stats.mostListenedMonth {
      let calendar = Calendar.current
      monthName = calendar.monthSymbols[month.month]
    } else {
      monthName = "N/A"
    }

    return YearInReviewStats(
      booksFinished: stats.numBooksFinished,
      timeSpent: stats.totalListeningTime,
      sessions: stats.totalListeningSessions,
      booksListened: stats.numBooksListened,
      topNarrator: .init(
        name: stats.mostListenedNarrator?.name ?? "N/A",
        time: stats.mostListenedNarrator?.time ?? 0
      ),
      topGenre: .init(
        name: stats.topGenres.first?.genre ?? "N/A",
        time: stats.topGenres.first?.time ?? 0
      ),
      topAuthor: .init(
        name: stats.topAuthors.first?.name ?? "N/A",
        time: stats.topAuthors.first?.time ?? 0
      ),
      topMonth: .init(
        name: monthName,
        time: stats.mostListenedMonth?.time ?? 0
      )
    )
  }

  private static func extractYearsFromDays(_ days: [String: Double]) -> [Int] {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let years = Set(
      days.keys.compactMap { dateString -> Int? in
        guard let date = dateFormatter.date(from: dateString) else { return nil }
        return Calendar.current.component(.year, from: date)
      }
    )
    return years.sorted(by: >)
  }

  private static func determineDefaultYear(from days: [String: Double]) -> Int {
    let calendar = Calendar.current
    let now = Date()
    let currentYear = calendar.component(.year, from: now)
    let currentMonth = calendar.component(.month, from: now)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let yearsWithData = Set(
      days.keys.compactMap { dateString -> Int? in
        guard let date = dateFormatter.date(from: dateString),
          days[dateString] ?? 0 > 0
        else { return nil }
        return calendar.component(.year, from: date)
      }
    )

    if currentMonth == 1 && yearsWithData.contains(currentYear - 1) {
      return currentYear - 1
    }

    if yearsWithData.contains(currentYear) {
      return currentYear
    }

    return currentYear
  }
}
