import Combine
import Foundation
import Logging
import ReadiumShared

final class EbookSearchViewModel: EbookSearchView.Model {
  enum State {
    case empty
    case starting
    case idle(SearchIterator)
    case loadingNext(SearchIterator, Task<Void, Never>)
    case end
    case failure(SearchError)
  }

  private var state: State = .empty
  private let publication: Publication
  private var searchTask: Task<Void, Never>?
  private var previousQuery: String = ""

  var onResultSelected: ((Locator, Int) -> Void)?
  var onDismissed: (() -> Void)?

  init(publication: Publication) {
    self.publication = publication
    super.init()
  }

  override var query: String {
    didSet {
      guard query != previousQuery else { return }
      previousQuery = query

      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        guard query == previousQuery else { return }

        if query.isEmpty {
          cancelSearch()
        } else {
          performSearch(query: query)
        }
      }
    }
  }

  private func performSearch(query: String) {
    cancelSearch()

    state = .starting
    isSearching = true

    searchTask = Task {
      switch await publication.search(query: query) {
      case .success(let iterator):
        self.state = .idle(iterator)
        self.loadNextPage()

      case .failure(let error):
        AppLogger.viewModel.error("Search failed: \(error)")
        self.state = .failure(error)
        self.isSearching = false
      }
    }
  }

  private func loadNextPage() {
    guard case .idle(let iterator) = state else {
      return
    }

    isLoadingMore = true
    state = .loadingNext(
      iterator,
      Task {
        switch await iterator.next() {
        case .success(let collection):
          if let collection {
            self.results.append(contentsOf: collection.locators)
            self.state = .idle(iterator)
          } else {
            self.state = .end
          }
          self.isSearching = false
          self.isLoadingMore = false

        case .failure(let error):
          AppLogger.viewModel.error("Failed to load next page: \(error)")
          self.state = .failure(error)
          self.isSearching = false
          self.isLoadingMore = false
        }
      }
    )
  }

  override func onLoadNextPage() {
    loadNextPage()
  }

  override func onResultSelected(locator: Locator, index: Int) {
    onResultSelected?(locator, index)
  }

  override func onDismiss() {
    cancelSearch()
    onDismissed?()
  }

  private func cancelSearch() {
    switch state {
    case .loadingNext(_, let task):
      task.cancel()
    default:
      break
    }

    searchTask?.cancel()
    searchTask = nil

    results.removeAll()
    state = .empty
    isSearching = false
    isLoadingMore = false
  }
}
