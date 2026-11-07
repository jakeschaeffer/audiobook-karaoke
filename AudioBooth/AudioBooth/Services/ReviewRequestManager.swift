import Foundation
import Logging
import StoreKit

final class ReviewRequestManager {
  static let shared = ReviewRequestManager()

  private let firstLaunchDateKey = "reviewFirstLaunchDate"
  private let lastReviewRequestDateKey = "reviewLastRequestDate"
  private let booksCompletedCountKey = "reviewBooksCompletedCount"
  private let reviewRequestCountKey = "reviewRequestCount"

  private let minimumBooksBeforeReview = 2
  private let minimumDaysSinceInstall = 7
  private let minimumDaysBetweenRequests = 120
  private let maximumLifetimeRequests = 3

  private init() {
    recordFirstLaunchIfNeeded()
  }

  func recordBookCompletion() {
    let currentCount = UserDefaults.standard.integer(forKey: booksCompletedCountKey)
    UserDefaults.standard.set(currentCount + 1, forKey: booksCompletedCountKey)

    AppLogger.general.info("Book completion recorded. Total: \(currentCount + 1)")

    checkAndRequestReviewIfEligible()
  }

  private func checkAndRequestReviewIfEligible() {
    guard isEligibleForReview() else { return }

    AppLogger.general.info("User is eligible for review request. Requesting...")

    requestReview()
  }

  private func isEligibleForReview() -> Bool {
    let booksCompleted = UserDefaults.standard.integer(forKey: booksCompletedCountKey)
    let requestCount = UserDefaults.standard.integer(forKey: reviewRequestCountKey)
    let lastRequestDate = UserDefaults.standard.double(forKey: lastReviewRequestDateKey)
    let firstLaunchDate = UserDefaults.standard.double(forKey: firstLaunchDateKey)

    guard booksCompleted >= minimumBooksBeforeReview else {
      AppLogger.general.debug(
        "Not eligible: only \(booksCompleted) books completed (need \(self.minimumBooksBeforeReview))"
      )
      return false
    }

    guard requestCount < maximumLifetimeRequests else {
      AppLogger.general.debug(
        "Not eligible: already requested \(requestCount) times (max \(self.maximumLifetimeRequests))"
      )
      return false
    }

    let daysSinceInstall =
      Date().timeIntervalSince(Date(timeIntervalSince1970: firstLaunchDate)) / (24 * 60 * 60)
    guard daysSinceInstall >= Double(minimumDaysSinceInstall) else {
      AppLogger.general.debug(
        "Not eligible: only \(Int(daysSinceInstall)) days since install (need \(self.minimumDaysSinceInstall))"
      )
      return false
    }

    if lastRequestDate > 0 {
      let daysSinceLastRequest =
        Date().timeIntervalSince(Date(timeIntervalSince1970: lastRequestDate)) / (24 * 60 * 60)
      guard daysSinceLastRequest >= Double(minimumDaysBetweenRequests) else {
        AppLogger.general.debug(
          "Not eligible: only \(Int(daysSinceLastRequest)) days since last request (need \(self.minimumDaysBetweenRequests))"
        )
        return false
      }
    }

    return true
  }

  private func requestReview() {
    let currentScene =
      UIApplication.shared.connectedScenes
      .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene

    guard let windowScene = currentScene else {
      AppLogger.general.warning("Cannot request review: no active window scene")
      return
    }

    SKStoreReviewController.requestReview(in: windowScene)

    let requestCount = UserDefaults.standard.integer(forKey: reviewRequestCountKey)
    UserDefaults.standard.set(requestCount + 1, forKey: reviewRequestCountKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastReviewRequestDateKey)

    AppLogger.general.info(
      "Review requested successfully. Total requests: \(requestCount + 1)"
    )
  }

  private func recordFirstLaunchIfNeeded() {
    guard UserDefaults.standard.double(forKey: firstLaunchDateKey) == 0 else { return }

    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: firstLaunchDateKey)
    AppLogger.general.info("First launch date recorded")
  }
}
