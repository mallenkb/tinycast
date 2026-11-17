import SwiftUI

struct WeatherSettingsView: View {
    @Environment(AppSettings.self) private var settings
    @State private var choosingCity = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle(isOn: $settings.weatherUseMacLocation) {
                    SettingsRowTitle(.weatherWeather, "Use Mac location")
                }
                LabeledContent {
                    HStack(spacing: Theme.Spacing.md) {
                        if !settings.weatherDefaultCity.isEmpty {
                            Text(settings.weatherDefaultCity)
                                .foregroundStyle(.secondary)
                            Button("Clear") { settings.weatherDefaultCity = "" }
                        }
                        if choosingCity {
                            Button("Cancel") { choosingCity = false }
                        } else {
                            Button("Choose city") { choosingCity = true }
                        }
                    }
                    .buttonStyle(.bordered)
                } label: {
                    SettingsRowTitle(.weatherWeather, "Default city")
                }
                if choosingCity {
                    WeatherCityPicker { city in
                        settings.weatherDefaultCity = city.label
                        choosingCity = false
                    }
                }
            } footer: {
                Text("When Use Mac location is off, weather uses your saved city.")
            }
            .settingsAnchor(.weatherWeather)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.weather)
    }
}

private struct WeatherCityPicker: View {
    let select: (WeatherPlace) -> Void

    @State private var query = ""
    @State private var result: Result<[WeatherPlace], Error>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            TextField("Search cities", text: $query, prompt: Text("Search cities"))
                .labelsHidden()
                .focused($searchFocused)
                .onChange(of: query) { result = nil }
                .onSubmit {
                    if case .success(let cities) = result, cities.count == 1, let city = cities.first {
                        select(city)
                    }
                }
            if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
                searchResults
            }
        }
        .defaultFocus($searchFocused, true)
        .task(id: query) { [query] in await search(query) }
    }

    @ViewBuilder
    private var searchResults: some View {
        switch result {
        case .success(let cities) where cities.isEmpty:
            Text("No cities found").foregroundStyle(.secondary)
        case .success(let cities):
            ForEach(cities, id: \.label) { city in
                Button {
                    select(city)
                } label: {
                    Text(city.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Theme.Spacing.xs)
                }
                .buttonStyle(.borderless)
            }
        case .failure:
            Text("City search unavailable").foregroundStyle(.secondary)
        case nil:
            ProgressView().controlSize(.small)
                .accessibilityLabel("Loading…")
        }
    }

    private func search(_ text: String) async {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        do {
            try await Task.sleep(for: .milliseconds(150))
            let cities = try await WeatherPlaces.suggestions(for: text)
            guard !Task.isCancelled, query == text else { return }
            result = .success(cities)
        } catch {
            guard !Task.isCancelled, query == text else { return }
            result = .failure(error)
        }
    }
}
