import API
import Combine
import SwiftUI

struct AuthenticationPage: View {
  @ObservedObject var model: AuthenticationView.Model

  var body: some View {
    Form {
      AuthenticationView(model: model)
    }
    .navigationTitle("Authentication")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview {
  NavigationStack {
    AuthenticationPage(model: .mock)
  }
}
