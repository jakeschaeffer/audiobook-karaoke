import API
import Foundation
import Logging

final class PodcastFeedViewModel: PodcastFeedView.Model {
  private var podcastsService: PodcastsService { Audiobookshelf.shared.podcasts }
  private var onServerKeys: Set<String> = []
  private var requestedGUIDs: Set<String> = []
  private var hasLoaded = false

  override func onAppear() {
    Task { await refresh() }
  }

  override func onRequestDownload(_ episode: PodcastFeedView.Model.Episode) {
    guard !requestedGUIDs.contains(episode.id) else { return }
    requestedGUIDs.insert(episode.id)
    updateEpisodeState(id: episode.id, state: .requested)

    Task {
      do {
        try await podcastsService.downloadEpisodes(
          podcastID: podcastID,
          episodes: [episode.feedEpisode]
        )
      } catch {
        AppLogger.viewModel.error("Failed to request episode download: \(error)")
        requestedGUIDs.remove(episode.id)
        updateEpisodeState(id: episode.id, state: .remote)
        self.error = "Failed to request download. Please try again."
      }
    }
  }

  private func refresh() async {
    if !hasLoaded {
      isLoading = true
    }

    async let feedTask = fetchFeed()
    async let serverTask = fetchOnServerKeys()
    let (feed, keys) = await (feedTask, serverTask)

    onServerKeys = keys

    if let feed {
      episodes = feed.episodes.map { feedEpisode in
        let publishedAt = feedEpisode.publishedAt.map {
          Date(timeIntervalSince1970: TimeInterval($0) / 1000)
        }
        let state: PodcastFeedView.Model.Episode.State = {
          if onServerKeys.contains(Self.key(title: feedEpisode.title, publishedAt: feedEpisode.publishedAt)) {
            return .onServer
          }
          if requestedGUIDs.contains(feedEpisode.guid) {
            return .requested
          }
          return .remote
        }()

        return PodcastFeedView.Model.Episode(
          id: feedEpisode.guid,
          title: feedEpisode.title,
          descriptionPlain: feedEpisode.descriptionPlain,
          publishedAt: publishedAt,
          durationSeconds: feedEpisode.durationSeconds,
          state: state,
          feedEpisode: feedEpisode
        )
      }
      error = nil
      hasLoaded = true
    } else if !hasLoaded {
      error = "Failed to load podcast feed. Please check your connection and try again."
    }

    isLoading = false
  }

  private func fetchFeed() async -> Podcast.Feed? {
    do {
      return try await podcastsService.fetchFeed(rssURL: feedURL)
    } catch {
      AppLogger.viewModel.error("Failed to fetch podcast feed: \(error)")
      return nil
    }
  }

  private func fetchOnServerKeys() async -> Set<String> {
    do {
      let podcast = try await podcastsService.fetch(id: podcastID)
      let apiEpisodes = podcast.media.episodes ?? []
      return Set(apiEpisodes.map { Self.key(title: $0.title, publishedAt: $0.publishedAt) })
    } catch {
      AppLogger.viewModel.error("Failed to fetch on-server episodes: \(error)")
      return onServerKeys
    }
  }

  private func updateEpisodeState(id: String, state: PodcastFeedView.Model.Episode.State) {
    guard let index = episodes.firstIndex(where: { $0.id == id }) else { return }
    episodes[index].state = state
  }

  private static func key(title: String, publishedAt: Int64?) -> String {
    "\(title.lowercased())|\(publishedAt ?? 0)"
  }
}
