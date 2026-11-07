import API
import Foundation
import Models
import WidgetKit

final class StatsPageViewModel: StatsPageView.Model {
  private let preferences = UserPreferences.shared
  private let sessionsPageSize = 20
  private var nextSessionsPage = 0
  private var totalSessionsPages = 0

  init() {
    super.init(isLoading: true, dailyGoalMinutes: UserPreferences.shared.dailyGoalMinutes)
  }

  override func onAppear() {
    Task {
      async let stats: Void = fetchStats()
      async let history: Void = fetchInitialSessions()
      _ = await (stats, history)
    }
  }

  private func fetchStats() async {
    do {
      let stats = try await Audiobookshelf.shared.authentication.fetchListeningStats()
      await processStats(stats)
    } catch {
      isLoading = false
    }
  }

  private func fetchInitialSessions() async {
    nextSessionsPage = 0
    recentSessions = []
    await fetchNextSessionsPage()
  }

  override func onLoadMoreSessions() {
    guard !isLoadingMoreSessions, hasMoreSessions else { return }
    Task { await fetchNextSessionsPage() }
  }

  private func fetchNextSessionsPage() async {
    guard !isLoadingMoreSessions else { return }
    isLoadingMoreSessions = true
    defer { isLoadingMoreSessions = false }

    do {
      let response = try await Audiobookshelf.shared.authentication.fetchListeningHistory(
        page: nextSessionsPage,
        itemsPerPage: sessionsPageSize
      )

      let new = response.sessions.map { session in
        StatsPageView.Model.SessionData(
          id: session.id,
          title: session.displayTitle ?? "Untitled",
          timeListening: session.timeListening ?? 0,
          updatedAt: session.updatedAt
        )
      }

      recentSessions.append(contentsOf: new)
      totalSessionsPages = response.numPages
      nextSessionsPage = response.page + 1
      hasMoreSessions = nextSessionsPage < totalSessionsPages
    } catch {
      hasMoreSessions = false
    }
  }

  override func onGoalChanged(_ minutes: Int) {
    dailyGoalMinutes = minutes
    preferences.dailyGoalMinutes = minutes

    if let sharedDefaults = UserDefaults(suiteName: AppGroup.identifier),
      let data = sharedDefaults.data(forKey: "listeningStats"),
      var stats = try? JSONDecoder().decode(WidgetStatsData.self, from: data)
    {
      stats = WidgetStatsData(
        todayTime: stats.todayTime,
        dailyGoalMinutes: minutes,
        weekData: stats.weekData,
        days: stats.days,
        daysInARow: stats.daysInARow
      )
      if let encoded = try? JSONEncoder().encode(stats) {
        sharedDefaults.set(encoded, forKey: "listeningStats")
        WidgetCenter.shared.reloadTimelines(ofKind: "DailyGoalWidget")
      }
    }
  }

  private func processStats(_ stats: ListeningStats) async {
    totalTime = stats.totalTime
    todayTime = stats.today

    daysListened = stats.days.values.filter { $0 > 0 }.count

    do {
      let allProgress = try MediaProgress.fetchAll()
      itemsFinished = allProgress.filter { $0.isFinished }.count
    } catch {
      itemsFinished = 0
    }

    listeningDays = stats.days

    if let items = stats.items {
      let (genres, authors, narrators) = Self.aggregateTopRanked(items: items)
      topGenres = genres
      topAuthors = authors
      topNarrators = narrators
    }

    isLoading = false
  }

  private static func aggregateTopRanked(
    items: [String: ListeningStats.Item]
  ) -> (
    genres: [StatsPageView.Model.RankedEntry],
    authors: [StatsPageView.Model.RankedEntry],
    narrators: [StatsPageView.Model.RankedEntry]
  ) {
    var genreTime: [String: Double] = [:]
    var authorTime: [String: Double] = [:]
    var authorTitles: [String: Int] = [:]
    var narratorTime: [String: Double] = [:]
    var narratorTitles: [String: Int] = [:]

    for item in items.values {
      guard let metadata = item.mediaMetadata else { continue }
      let seconds = item.timeListening ?? 0

      if let genres = metadata.genres {
        let share = genres.isEmpty ? seconds : seconds / Double(genres.count)
        for genre in genres {
          genreTime[genre, default: 0] += share
        }
      }

      if let authors = metadata.authors {
        let share = authors.isEmpty ? seconds : seconds / Double(authors.count)
        for author in authors {
          authorTime[author.name, default: 0] += share
          authorTitles[author.name, default: 0] += 1
        }
      }

      if let narrators = metadata.narrators {
        let share = narrators.isEmpty ? seconds : seconds / Double(narrators.count)
        for narrator in narrators {
          narratorTime[narrator, default: 0] += share
          narratorTitles[narrator, default: 0] += 1
        }
      }
    }

    let topN = 5

    let genres =
      genreTime
      .sorted { $0.value > $1.value }
      .prefix(topN)
      .map { StatsPageView.Model.RankedEntry(name: $0.key, subtitle: nil, seconds: $0.value) }

    let authors =
      authorTime
      .sorted { $0.value > $1.value }
      .prefix(topN)
      .map { entry in
        let titles = authorTitles[entry.key] ?? 0
        return StatsPageView.Model.RankedEntry(
          name: entry.key,
          subtitle: "\(titles) title\(titles == 1 ? "" : "s")",
          seconds: entry.value
        )
      }

    let narrators =
      narratorTime
      .sorted { $0.value > $1.value }
      .prefix(topN)
      .map { entry in
        let titles = narratorTitles[entry.key] ?? 0
        return StatsPageView.Model.RankedEntry(
          name: entry.key,
          subtitle: "\(titles) title\(titles == 1 ? "" : "s")",
          seconds: entry.value
        )
      }

    return (Array(genres), Array(authors), Array(narrators))
  }
}
