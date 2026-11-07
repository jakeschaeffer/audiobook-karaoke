import SwiftUI
import Transcription

#if SPEAKER_STACK

/// One address. The server says what it offers, and the app shows what it found.
struct CompanionSettingsView: View {
  @Environment(\.appTheme) private var theme
  @State private var store = CompanionStore.shared
  @State private var address = ""
  @State private var workerAddress = ""
  @State private var connecting = false
  @State private var errorMessage: String?
  @FocusState private var focused: Bool

  var body: some View {
    Form {
      Section {
        TextField(text: $address, prompt: Text(verbatim: "https://captions.example.com")) {
          Text("Server address", tableName: "Companion")
        }
        .keyboardType(.URL)
        .textContentType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focused)
        .submitLabel(.go)
        .onSubmit(connect)
        .listRowBackground(theme.colors.background.card)

        Button(action: connect) {
          HStack {
            Text(store.isConfigured ? "Save and Check" : "Connect", tableName: "Companion")
            if connecting {
              Spacer()
              ProgressView()
            }
          }
        }
        .disabled(connecting || address.trimmingCharacters(in: .whitespaces).isEmpty)
        .listRowBackground(theme.colors.background.card)

        if let errorMessage {
          Label {
            Text(errorMessage)
          } icon: {
            Image(systemName: "exclamationmark.triangle")
          }
          .font(.footnote)
          .foregroundStyle(.red)
          .listRowBackground(theme.colors.background.card)
        }
      } header: {
        Text("Address", tableName: "Companion")
      } footer: {
        Text(
          "Optional. A companion server adds server transcripts, and playback on a speaker. Enter its address once; the rest comes from the server. Without one, everything else still works, and iPhone can transcribe on its own.",
          tableName: "Companion"
        )
      }

      if store.isConfigured {
        foundSection
        advancedSection
        Section {
          Button(role: .destructive) {
            store.disconnect()
            address = ""
            workerAddress = ""
            errorMessage = nil
          } label: {
            Text("Remove Server", tableName: "Companion")
          }
          .listRowBackground(theme.colors.background.card)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .background(theme.colors.background.page)
    .navigationTitle(Text("Companion Server", tableName: "Companion"))
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      address = store.daemonURL?.absoluteString ?? ""
      workerAddress = store.workerOverride?.absoluteString ?? ""
    }
    .task { await store.refresh() }
  }

  private var foundSection: some View {
    Section {
      featureRow(
        title: Text("Transcripts", tableName: "Companion"),
        systemImage: "text.bubble",
        available: store.supportsTranscripts,
        detail: nil
      )
      featureRow(
        title: Text("Speaker", tableName: "Companion"),
        systemImage: "hifispeaker",
        available: store.supportsSpeaker,
        detail: store.capabilities?.speakerName
      )
      featureRow(
        title: Text("Transcribe on Server", tableName: "Companion"),
        systemImage: "waveform",
        available: store.supportsServerJobs,
        detail: nil
      )
    } header: {
      Text("Found on this server", tableName: "Companion")
    } footer: {
      if let stale = store.lastRefreshError {
        Text("Couldn't check just now, so this is the last answer. \(stale)", tableName: "Companion")
      }
    }
  }

  private var advancedSection: some View {
    Section {
      TextField(text: $workerAddress, prompt: Text("Found automatically", tableName: "Companion")) {
        Text("Worker address", tableName: "Companion")
      }
      .keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
      .listRowBackground(theme.colors.background.card)
    } header: {
      Text("Advanced", tableName: "Companion")
    } footer: {
      Text(
        "Only for a server that can't tell the app where its transcription worker is. Save and Check applies it.",
        tableName: "Companion"
      )
    }
  }

  private func featureRow(title: Text, systemImage: String, available: Bool, detail: String?) -> some View {
    HStack {
      Label {
        title
      } icon: {
        Image(systemName: systemImage)
      }
      Spacer()
      if available, let detail {
        Text(detail)
          .foregroundStyle(.secondary)
      }
      Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
        .foregroundStyle(available ? Color.green : Color.secondary)
        .accessibilityLabel(
          available ? Text("Available", tableName: "Companion") : Text("Not available", tableName: "Companion")
        )
    }
    .listRowBackground(theme.colors.background.card)
  }

  private func connect() {
    guard !connecting else { return }
    focused = false
    connecting = true
    errorMessage = nil
    Task {
      defer { connecting = false }
      do {
        try await store.connect(
          address: address,
          workerAddress: workerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        address = store.daemonURL?.absoluteString ?? address
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }
}

#endif
