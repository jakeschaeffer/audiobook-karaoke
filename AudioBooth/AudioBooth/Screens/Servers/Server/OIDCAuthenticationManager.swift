import API
import AuthenticationServices
import CryptoKit
import Foundation
import Logging
import SwiftUI

final class OIDCAuthenticationManager {
  private let serverURL: String
  private let pkce: PKCE
  private let customHeaders: [String: String]
  private let existingServerID: String?

  init(serverURL: String, customHeaders: [String: String] = [:], existingServerID: String? = nil) {
    self.serverURL = serverURL
    self.pkce = PKCE()
    self.customHeaders = customHeaders
    self.existingServerID = existingServerID
  }

  func start(using session: WebAuthenticationSession) async throws -> String {
    AppLogger.authentication.info(
      "Starting OIDC authentication for server: \(self.serverURL)"
    )

    let authURL = try buildOIDCURL()
    let (redirectURL, cookies) = try await makeInitialOAuthRequest(authURL: authURL)

    let callbackURL: URL

    if #available(iOS 17.4, *) {
      callbackURL = try await session.authenticate(
        using: redirectURL,
        callback: .customScheme("audiobooth"),
        preferredBrowserSession: .shared,
        additionalHeaderFields: customHeaders
      )
    } else {
      callbackURL = try await session.authenticate(
        using: redirectURL,
        callbackURLScheme: "audiobooth",
        preferredBrowserSession: .shared
      )
    }

    return try await handleAuthenticationResult(callbackURL: callbackURL, cookies: cookies)
  }

  private func handleAuthenticationResult(
    callbackURL: URL,
    cookies: [HTTPCookie]
  ) async throws -> String {
    AppLogger.authentication.info(
      "Received callback URL: \(callbackURL)"
    )

    guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      let queryItems = components.queryItems
    else {
      AppLogger.authentication.error("Failed to parse callback URL components")
      throw OIDCError.invalidCallback
    }

    let allParams = queryItems.map { "\($0.name): \($0.value ?? "nil")" }.joined(separator: ", ")
    AppLogger.authentication.info("Callback query parameters: \(allParams)")

    let code = queryItems.first { $0.name == "code" }?.value
    let state = queryItems.first { $0.name == "state" }?.value
    let error = queryItems.first { $0.name == "error" }?.value

    if let error {
      AppLogger.authentication.error(
        "Authentication failed with error parameter: \(error)"
      )
      throw OIDCError.authenticationFailed(error)
    }

    guard let authCode = code else {
      let availableParams = queryItems.map { "\($0.name): \($0.value ?? "nil")" }.joined(
        separator: ", "
      )
      AppLogger.authentication.error(
        "No authorization code in callback. Available params: \(availableParams)"
      )
      throw OIDCError.noAuthorizationCode(availableParams)
    }

    AppLogger.authentication.info(
      "Calling API loginWithOIDC - code length: \(authCode.count), verifier length: \(self.pkce.verifier.count), state: \(state ?? "nil"), cookies count: \(cookies.count), custom headers count: \(self.customHeaders.count)"
    )

    let connectionID = try await Audiobookshelf.shared.authentication.loginWithOIDC(
      serverURL: serverURL,
      code: authCode,
      verifier: pkce.verifier,
      state: state,
      cookies: cookies,
      customHeaders: customHeaders,
      existingServerID: existingServerID
    )

    AppLogger.authentication.info("OIDC authentication succeeded")
    return connectionID
  }

  private func buildOIDCURL() throws -> URL {
    guard let baseURL = URL(string: serverURL) else {
      AppLogger.authentication.error("Invalid server URL: \(self.serverURL)")
      throw OIDCError.invalidServerURL
    }

    var components = URLComponents(
      url: baseURL.appendingPathComponent("/auth/openid"),
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "client_id", value: "AudioBooth"),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: "openid"),
      URLQueryItem(name: "redirect_uri", value: "audiobooth://oauth"),
      URLQueryItem(name: "callback", value: "audiobooth://oauth"),
      URLQueryItem(name: "code_challenge", value: pkce.challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256"),
    ]

    guard let authURL = components?.url else {
      AppLogger.authentication.error("Failed to construct authorization URL from components")
      throw OIDCError.failedToConstructURL
    }

    AppLogger.authentication.info("Built OIDC URL: \(authURL)")
    AppLogger.authentication.debug("PKCE challenge: \(self.pkce.challenge)")
    AppLogger.authentication.debug(
      "PKCE verifier length: \(self.pkce.verifier.count)"
    )

    return authURL
  }

  private func makeInitialOAuthRequest(authURL: URL) async throws -> (URL, [HTTPCookie]) {
    AppLogger.authentication.info(
      "Making initial OAuth request to: \(authURL)"
    )

    var request = URLRequest(url: authURL)
    request.httpMethod = "GET"
    request.allHTTPHeaderFields = customHeaders

    let config = URLSessionConfiguration.ephemeral
    let session = URLSession(
      configuration: config,
      delegate: NoRedirectDelegate(),
      delegateQueue: nil
    )

    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      AppLogger.authentication.error("Invalid HTTP response received")
      throw URLError(.badServerResponse)
    }

    AppLogger.authentication.info(
      "Received HTTP response with status code: \(httpResponse.statusCode)"
    )

    if httpResponse.statusCode == 302,
      let locationString = httpResponse.allHeaderFields["Location"] as? String,
      let redirectURL = URL(string: locationString)
    {
      let cookies = HTTPCookie.cookies(
        withResponseHeaderFields: (httpResponse.allHeaderFields as? [String: String]) ?? [:],
        for: authURL
      )
      AppLogger.authentication.info(
        "Received redirect to: \(redirectURL)"
      )
      AppLogger.authentication.info(
        "Captured \(cookies.count) cookies: \(cookies.map { $0.name }.joined(separator: ", "))"
      )
      return (redirectURL, cookies)
    } else if httpResponse.statusCode == 400, let error = String(data: data, encoding: .utf8) {
      AppLogger.authentication.error("Received 400 Bad Request: \(error)")
      if error == "Invalid redirect_uri" {
        throw OIDCError.invalidCallback
      } else {
        throw OIDCError.badRequest(error)
      }
    }

    AppLogger.authentication.error(
      "Unexpected response status: \(httpResponse.statusCode)"
    )
    if let responseBody = String(data: data, encoding: .utf8) {
      AppLogger.authentication.error("Response body: \(responseBody)")
    }
    throw URLError(.badServerResponse)
  }
}

extension OIDCAuthenticationManager {
  struct PKCE {
    let verifier: String
    let challenge: String

    init() {
      var buffer = [UInt8](repeating: 0, count: 32)
      _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)

      verifier = Data(buffer)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

      let data = Data(verifier.utf8)
      let hash = SHA256.hash(data: data)
      challenge = Data(hash)
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    }
  }
}

enum OIDCError: LocalizedError {
  case invalidCallback
  case authenticationFailed(String)
  case noAuthorizationCode(String)
  case invalidServerURL
  case failedToConstructURL
  case badRequest(String)

  var errorDescription: String? {
    switch self {
    case .invalidCallback:
      return "Add **audiobooth://oauth** to your **Allowed Mobile Redirect URIs**"
    case .authenticationFailed(let error):
      return "Authentication failed: \(error)"
    case .noAuthorizationCode(let available):
      return "No authorization code found. Available parameters: \(available)"
    case .invalidServerURL:
      return "Invalid server URL"
    case .failedToConstructURL:
      return "Failed to construct authorization URL"
    case .badRequest(let error):
      return error
    }
  }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
