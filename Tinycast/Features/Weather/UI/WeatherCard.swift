import SwiftUI

struct WeatherCard: View {
    let query: WeatherQuery
    let selected: Bool

    @Environment(WeatherCoordinator.self) private var coordinator
    @Environment(PaletteState.self) private var palette
    @Environment(AppSettings.self) private var settings
    @Environment(\.metrics) private var metrics
    @State private var response: Response?
    @State private var retry = 0
    @State private var periodOverride: Period?
    @State private var metricOverride: Metric?
    @State private var selectedDay: Date?

    private struct Request: Equatable {
        let place: WeatherQuery.Place?
        let retry: Int
    }

    private struct Response {
        let place: WeatherQuery.Place
        let result: Result<WeatherForecast, WeatherService.Failure>
    }

    private enum Period: Hashable {
        case today, week, requested
    }

    private enum Metric: CaseIterable, Hashable {
        case conditions, rain, wind

        var title: String {
            switch self {
            case .conditions: String(localized: "Conditions")
            case .rain: String(localized: "Precipitation")
            case .wind: String(localized: "Wind")
            }
        }

        var symbol: String {
            switch self {
            case .conditions: "cloud.sun"
            case .rain: "drop"
            case .wind: "wind"
            }
        }

        func detail(for period: Period, temperatureUnit: String, speedUnit: String) -> LocalizedStringKey {
            switch (self, period) {
            case (.conditions, .week): "Daily high and low (\(temperatureUnit))"
            case (.rain, .week): "Maximum chance · Total precipitation"
            case (.wind, .week): "Maximum speed and gusts (\(speedUnit))"
            case (.conditions, _): "Temperature (\(temperatureUnit))"
            case (.rain, _): "Chance and precipitation in the previous hour"
            case (.wind, _): "Speed and gusts (\(speedUnit))"
            }
        }
    }

    private var metric: Metric {
        if let metricOverride { return metricOverride }
        switch query.metric {
        case .rain: return .rain
        case .wind: return .wind
        default: return .conditions
        }
    }

    var body: some View {
        let place = query.place
        let request = Request(place: palette.isVisible ? place : nil, retry: retry)
        let result = response.flatMap { $0.place == request.place ? $0.result : nil }
        Group {
            if place == .setup {
                status("Choose a location for weather") {
                    HStack(spacing: metrics.spacing.sm) {
                        Button("Use Mac location") { settings.weatherUseMacLocation = true }
                        Button("Open Settings") { coordinator.showSettings() }
                    }
                }
            } else if place == .missingCity {
                status("Enter a city") { EmptyView() }
            } else {
                switch result {
                case .success(let forecast): contents(forecast)
                case .failure(let failure): status(failure)
                case nil: status(nil)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: request) { await load(request) }
        .onChange(of: query) {
            periodOverride = nil
            metricOverride = nil
            selectedDay = nil
        }
    }

    @ViewBuilder
    private func status(_ failure: WeatherService.Failure?) -> some View {
        switch failure {
        case .locationNotFound:
            status("City not found. Check the name or add a country.") { EmptyView() }
        case .locationDenied:
            status("Allow location access for Tinycast in System Settings, or search by city.") {
                Button("Open Settings") { coordinator.showSettings() }
            }
        case .macLocationUnavailable:
            status("Couldn’t get your Mac’s location") {
                HStack(spacing: metrics.spacing.sm) {
                    retryButton
                    Button("Open Settings") { coordinator.showSettings() }
                }
            }
        case .unavailable:
            status("Weather unavailable") { retryButton }
        case nil:
            WeatherLoadingCard()
        }
    }

    private func status<Actions: View>(
        _ title: LocalizedStringKey, @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: metrics.spacing.xl) {
            HStack(spacing: metrics.spacing.md) {
                Image(systemName: "cloud").accessibilityHidden(true)
                Text(title)
            }
            actions()
        }
        .font(metrics.typography.rowTitle)
        .foregroundStyle(.secondary)
        .buttonStyle(.bordered)
        .padding(.horizontal, metrics.spacing.xxl)
        .padding(.vertical, metrics.spacing.md * 2)
        .frame(minHeight: metrics.scaled(64))
        .frame(maxWidth: .infinity)
        .leadCard(selected: selected)
    }

    private var retryButton: some View {
        Button("Retry") {
            response = nil
            retry += 1
        }
    }

    private func load(_ request: Request) async {
        guard !Task.isCancelled else { return }
        response = nil
        guard let place = request.place, place != .setup, place != .missingCity else { return }
        do {
            let result = try await coordinator.forecast(for: place)
            guard isCurrent(place) else { return }
            response = Response(place: place, result: .success(result))
        } catch {
            guard isCurrent(place), !(error is CancellationError) else { return }
            let failure = (error as? WeatherService.Failure) ?? .unavailable
            response = Response(place: place, result: .failure(failure))
        }
    }

    private func isCurrent(_ place: WeatherQuery.Place) -> Bool {
        !Task.isCancelled && palette.isVisible
            && WeatherQuery(palette.query, defaultCity: settings.weatherDefaultCity,
                            useMacLocation: settings.weatherUseMacLocation)?.place == place
    }

    private func contents(_ forecast: WeatherForecast) -> some View {
        let selection = query.timing.flatMap { WeatherForecastSelection.resolve($0, in: forecast) }
        let defaultPeriod: Period = query.timing == nil ? .today : .requested
        let period = periodOverride ?? defaultPeriod
        return VStack(alignment: .leading, spacing: metrics.spacing.md) {
            HStack {
                Text("Weather")
                    .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                periodPicker(period, forecast: forecast)
            }
            .padding(.horizontal, metrics.spacing.xs)

            VStack(alignment: .leading, spacing: metrics.spacing.lg) {
                switch period {
                case .today:
                    dailyForecast(forecast)
                case .week:
                    dailyForecast(forecast, week: true)
                case .requested:
                    if let selection {
                        if let hour = selection.hour {
                            requested(forecast, hour: hour, requestedTime: selection.requestedTime)
                            hourly(forecast, startingAt: hour)
                        } else {
                            weekly(forecast, requestedDays: selection.days)
                        }
                    } else {
                        Text("Forecast unavailable for the requested date or time")
                            .font(metrics.typography.rowTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                if period != .week { dayStrip(forecast) }
            }
            .padding(.horizontal, metrics.scaled(Theme.Weather.inset))
            .padding(.vertical, metrics.spacing.xl)
            .background(Theme.Colors.weatherCardFill,
                        in: RoundedRectangle(cornerRadius: metrics.scaled(Theme.Weather.cornerRadius)))
            attribution
        }
    }

    private func periodPicker(_ period: Period, forecast: WeatherForecast) -> some View {
        HStack(spacing: metrics.spacing.xxs) {
            periodButton(.today, active: period) {
                if let selectedDay {
                    Text(selectedDay, format: Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated))
                } else {
                    Text("Today")
                }
            }
            periodButton(.week, active: period) { Text("This Week") }
            if query.timing != nil {
                periodButton(.requested, active: period) { Text("Requested forecast") }
            }
        }
        .padding(metrics.spacing.xs)
        .background(Theme.Colors.weatherControlTrack, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Forecast period"))
    }

    private func periodButton<Label: View>(
        _ value: Period, active: Period, @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            if value == .requested { selectedDay = nil }
            periodOverride = value
        } label: {
            label()
                .font(metrics.typography.caption)
                .foregroundStyle(active == value ? .primary : .secondary)
                .padding(.horizontal, metrics.spacing.xl)
                .padding(.vertical, metrics.spacing.sm)
                .background {
                    if active == value { Capsule().fill(Theme.Colors.weatherControlSelection) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active == value ? .isSelected : [])
    }

    private func dailyForecast(_ forecast: WeatherForecast, week: Bool = false) -> some View {
        HStack(alignment: .top, spacing: metrics.scaled(Theme.Weather.inset)) {
            overview(forecast)
                .frame(width: metrics.scaled(Theme.Weather.overviewWidth), alignment: .leading)
                .padding(.trailing, metrics.scaled(Theme.Weather.inset))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(Theme.Colors.separator).frame(width: 1)
                }
            forecastTimeline(forecast, week: week)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func forecastTimeline(_ forecast: WeatherForecast, week: Bool) -> some View {
        if week {
            weekly(forecast)
        } else if selectedDay != nil, selectedHours(forecast).isEmpty {
            Text("Forecast unavailable for the requested date or time")
                .foregroundStyle(.secondary)
        } else {
            hourly(forecast, startingAt: selectedHours(forecast).first)
        }
    }

    private func selectedHours(_ forecast: WeatherForecast) -> [WeatherHour] {
        guard let selectedDay else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        return forecast.hours.filter { calendar.isDate($0.time, inSameDayAs: selectedDay) }
    }

    private func overview(_ forecast: WeatherForecast) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let date = selectedDay ?? forecast.current.time
        let day = forecast.days.first { calendar.isDate($0.date, inSameDayAs: date) }
        let condition = selectedDay == nil ? forecast.current.condition : day?.condition
        let value = selectedDay == nil ? forecast.current.temperature : day?.high
        let dateStyle = Date.FormatStyle(timeZone: forecast.timeZone).weekday(.wide).month(.wide).day()
        return VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            VStack(alignment: .leading, spacing: metrics.spacing.xs) {
                Text(verbatim: forecast.place)
                    .font(.system(size: metrics.scaled(Theme.Weather.titleSize), weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(date, format: dateStyle)
                    .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: metrics.spacing.md) {
                Text(verbatim: temperature(value))
                    .font(.system(size: metrics.scaled(Theme.Weather.temperatureSize), weight: .medium))
                    .tracking(-metrics.spacing.xxs)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let condition {
                    WeatherIcon(condition: condition, size: metrics.scaled(Theme.Weather.overviewIllustration))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: metrics.scaled(Theme.Weather.readingHeight))
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                if let condition { Text(conditionTitle(condition))
                    .font(.system(size: metrics.scaled(Theme.Weather.conditionSize), weight: .medium)) }
                if selectedDay == nil, let apparent = forecast.current.apparentTemperature {
                    Text("Feels like \(temperature(apparent))").foregroundStyle(.secondary)
                }
                if let day {
                    Text("High \(temperature(day.high)) · Low \(temperature(day.low))")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dayStrip(_ forecast: WeatherForecast) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let weekday = Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated)
        let index = selectedDay.flatMap { date in
            forecast.days.firstIndex { calendar.isDate($0.date, inSameDayAs: date) }
        } ?? 0
        let start = index < 7 ? 0 : max(0, min(index - 3, forecast.days.count - 7))
        let days = Array(forecast.days.dropFirst(start).prefix(7))
        return VStack(spacing: metrics.scaled(Theme.Weather.dayStripInset)) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.spacing.xs) {
                    ForEach(days, id: \.date) { day in dayButton(day, forecast: forecast, weekday: weekday) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.scaled(Theme.Weather.hourWidth)))]) {
                    ForEach(days, id: \.date) { day in dayButton(day, forecast: forecast, weekday: weekday) }
                }
            }
        }
    }

    private func dayButton(
        _ day: WeatherDay, forecast: WeatherForecast, weekday: Date.FormatStyle
    ) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let today = calendar.isDate(day.date, inSameDayAs: forecast.current.time)
        let active = calendar.isDate(day.date, inSameDayAs: selectedDay ?? forecast.current.time)
        return Button {
            selectedDay = today ? nil : day.date
            periodOverride = .today
        } label: {
            VStack(spacing: metrics.spacing.xs) {
                Group {
                    if today { Text("Today") } else { Text(day.date, format: weekday) }
                }
                .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                WeatherIcon(condition: day.condition, size: metrics.scaled(Theme.Weather.dayArtworkSize))
                    .frame(height: metrics.scaled(Theme.Weather.dayArtworkHeight))
                    .accessibilityHidden(true)
                HStack(spacing: metrics.spacing.xs) {
                    Text(verbatim: temperature(day.high))
                    Text(verbatim: "/").foregroundStyle(.secondary)
                    Text(verbatim: temperature(day.low)).foregroundStyle(.secondary)
                }
                .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                .monospacedDigit()
            }
            .frame(minWidth: metrics.scaled(50), maxWidth: .infinity)
            .padding(.vertical, metrics.spacing.xs)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: metrics.radius.row)
                        .fill(Theme.Colors.weatherControlSelection)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: metrics.radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func requested(_ forecast: WeatherForecast, hour: WeatherHour, requestedTime: Date?) -> some View {
        let dateTime = Date.FormatStyle(timeZone: forecast.timeZone)
            .weekday(.wide).month(.abbreviated).day().hour().minute()
        let time = Date.FormatStyle(timeZone: forecast.timeZone).hour().minute()
        return HStack(spacing: metrics.spacing.md) {
            VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                Text(verbatim: forecast.place)
                    .font(metrics.typography.rowTitle.weight(.semibold))
                    .lineLimit(1)
                Text(hour.time, format: dateTime)
                    .font(metrics.typography.rowTitle)
                if let requestedTime, requestedTime != hour.time {
                    Text("Requested \(requestedTime.formatted(time))")
                        .foregroundStyle(.secondary)
                }
                switch metric {
                case .conditions:
                    Text(verbatim: temperature(hour.temperature))
                        .font(metrics.typography.calcResult)
                    Text(conditionTitle(hour.condition))
                case .rain:
                    Text(verbatim: percent(hour.precipitationProbability))
                        .font(metrics.typography.calcResult)
                    Text(verbatim: measurement(hour.precipitation, unit: UnitLength.millimeters, fractionDigits: 1))
                case .wind:
                    Text(verbatim: measurement(hour.windSpeed, unit: UnitSpeed.kilometersPerHour))
                        .font(metrics.typography.calcResult)
                    Text("Gust \(measurement(hour.windGusts, unit: UnitSpeed.kilometersPerHour))")
                }
            }
            .font(metrics.typography.caption)
            .monospacedDigit()
            Spacer(minLength: 0)
            WeatherIcon(condition: hour.condition, size: metrics.scaled(62))
                .accessibilityHidden(true)
        }
    }

    private enum HourSlot: Identifiable {
        case current(WeatherCurrent, WeatherHour?)
        case reading(WeatherHour)
        case sunset(Date)

        enum ID: Hashable {
            case current
            case reading(Date)
            case sunset(Date)
        }

        var id: ID {
            switch self {
            case .current: .current
            case .reading(let hour): .reading(hour.time)
            case .sunset(let date): .sunset(date)
            }
        }

        var time: Date {
            switch self {
            case .current(let reading, _): reading.time
            case .reading(let hour): hour.time
            case .sunset(let date): date
            }
        }

        var hour: WeatherHour? {
            switch self {
            case .current(_, let hour): hour
            case .reading(let hour): hour
            case .sunset: nil
            }
        }
    }

    private func hourly(_ forecast: WeatherForecast, startingAt requestedHour: WeatherHour? = nil) -> some View {
        let slots = hourSlots(forecast, startingAt: requestedHour)
        let time = Date.FormatStyle(timeZone: forecast.timeZone).hour().minute()
        let currentPrecipitation = requestedHour == nil ? currentPrecipitationHour(forecast) : nil
        let rainScale = max(1, slots.compactMap { $0.id == .current ? nil : $0.hour?.precipitation }.max() ?? 0)
        let windScale = max(10, slots.map {
            max($0.hour?.windSpeed ?? 0, $0.hour?.windGusts ?? 0, forecast.current.windSpeed ?? 0)
        }.max() ?? 0)
        return VStack(alignment: .leading, spacing: metrics.spacing.md) {
            metricHeader(period: .today)
            WeatherTimeline(identity: slots.first?.id) {
                ForEach(slots) { slot in
                    VStack(spacing: metrics.spacing.xs) {
                        Group {
                            if slot.id == .current {
                                Text("Now")
                            } else {
                                Text(slot.time, format: time)
                            }
                        }
                        .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                        .foregroundStyle(slot.id == requestedHour.map { .reading($0.time) }
                            ? Color.accentColor : Color.secondary)
                        switch slot {
                        case .current(let reading, let hour):
                            currentValues(reading, hour: hour, precipitation: currentPrecipitation,
                                          rainScale: rainScale, windScale: windScale)
                        case .reading(let hour):
                            hourlyValues(hour, rainScale: rainScale, windScale: windScale)
                        case .sunset:
                            WeatherSunsetIcon(size: metrics.scaled(Theme.Weather.hourlyIllustration))
                                .frame(height: metrics.scaled(Theme.Weather.illustrationHeight))
                                .accessibilityHidden(true)
                            Text("Sunset")
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: metrics.scaled(Theme.Weather.hourWidth))
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.system(size: metrics.scaled(Theme.Weather.titleSize), weight: .semibold))
            .monospacedDigit()
            HStack(spacing: metrics.spacing.xs) {
                Text(selectedDay ?? forecast.current.time,
                     format: Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated))
                Text(verbatim: "·")
                Text("Hourly forecast")
            }
            .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
            .foregroundStyle(.secondary)
        }
    }

    private func metricHeader(period: Period) -> some View {
        let heading = VStack(alignment: .leading, spacing: metrics.spacing.xxs) {
            Text(verbatim: metric.title).font(.system(size: metrics.scaled(Theme.Weather.titleSize), weight: .semibold))
            Text(metric.detail(for: period,
                               temperatureUnit: UnitTemperature(forLocale: .autoupdatingCurrent, usage: .weather).symbol,
                               speedUnit: UnitSpeed(forLocale: .autoupdatingCurrent, usage: .wind).symbol))
                .font(.system(size: metrics.scaled(Theme.Weather.detailSize)))
                .foregroundStyle(.secondary)
        }
        let label: LocalizedStringKey = period == .today ? "Hourly forecast" : "Daily forecast"
        let picker = HStack(spacing: metrics.spacing.xxs) {
            ForEach(Metric.allCases, id: \.self) { item in
                let active = metric == item
                Button {
                    metricOverride = item
                } label: {
                    SymbolImage(name: item.symbol, size: metrics.scaled(18), monochrome: true)
                        .foregroundStyle(active ? .primary : .secondary)
                        .frame(width: metrics.scaled(Theme.Weather.metricWidth),
                               height: metrics.scaled(Theme.Weather.metricHeight))
                        .background {
                            if active { Capsule().fill(Theme.Colors.weatherControlSelection) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: item.title))
                .accessibilityAddTraits(active ? .isSelected : [])
                .tooltip(item.title)
            }
        }
        .padding(metrics.spacing.xxs)
        .background(Theme.Colors.weatherControlTrack, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(label))
        .fixedSize()
        return HStack(alignment: .center, spacing: metrics.spacing.md) {
            heading.frame(maxWidth: .infinity, alignment: .leading)
            picker
        }
    }

    private func hourSlots(_ forecast: WeatherForecast, startingAt requestedHour: WeatherHour?) -> [HourSlot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = forecast.timeZone
        let currentHour = calendar.dateInterval(of: .hour, for: forecast.current.time)
        let start = requestedHour?.time ?? currentHour?.end ?? forecast.current.time
        let source = selectedDay == nil ? forecast.hours : selectedHours(forecast)
        let hours = Array(source.lazy.filter { $0.time >= start }.prefix(24))
        var slots = hours.map(HourSlot.reading)
        let after = requestedHour?.time ?? forecast.current.time
        if let sunset = forecast.days.compactMap(\.sunset).first(where: { $0 > after }),
            let slot = hours.firstIndex(where: { $0.time >= sunset })
        {
            slots.insert(.sunset(sunset), at: slot)
        }
        if requestedHour == nil, selectedDay == nil {
            let hour = forecast.hours.first { $0.time == currentHour?.start }
            slots.insert(.current(forecast.current, hour), at: 0)
        }
        return slots
    }

    private func currentPrecipitationHour(_ forecast: WeatherForecast) -> WeatherHour? {
        let time = forecast.current.time
        return forecast.hours.first {
            let offset = $0.time.timeIntervalSince(time)
            return (0..<3600).contains(offset)
        }
    }

    @ViewBuilder
    private func currentValues(
        _ reading: WeatherCurrent, hour: WeatherHour?, precipitation: WeatherHour?,
        rainScale: Double, windScale: Double
    ) -> some View {
        switch metric {
        case .conditions:
            conditionValues(reading.condition, value: reading.temperature)
        case .rain:
            rainValues(chance: precipitation?.precipitationProbability, amount: nil, scale: rainScale)
        case .wind:
            windValues(speed: reading.windSpeed ?? hour?.windSpeed, gusts: hour?.windGusts, scale: windScale)
        }
    }

    @ViewBuilder
    private func hourlyValues(_ hour: WeatherHour, rainScale: Double, windScale: Double) -> some View {
        switch metric {
        case .conditions:
            conditionValues(hour.condition, value: hour.temperature)
        case .rain:
            rainValues(chance: hour.precipitationProbability, amount: hour.precipitation, scale: rainScale)
        case .wind:
            windValues(speed: hour.windSpeed, gusts: hour.windGusts, scale: windScale)
        }
    }

    private func conditionValues(_ condition: WeatherCondition, value: Double?) -> some View {
        Group {
            WeatherIcon(condition: condition, size: metrics.scaled(Theme.Weather.hourlyIllustration))
                .accessibilityLabel(Text(conditionTitle(condition)))
                .frame(height: metrics.scaled(Theme.Weather.illustrationHeight))
            Text(verbatim: temperature(value))
        }
    }

    private func rainValues(chance: Double?, amount: Double?, scale: Double) -> some View {
        Group {
            metricBar(total: amount, scale: scale, color: .blue)
                .frame(height: metrics.scaled(Theme.Weather.illustrationHeight))
            Text(verbatim: percent(chance))
            if let amount {
                Text(verbatim: measurement(amount, unit: UnitLength.millimeters, fractionDigits: 1))
                    .font(metrics.typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func windValues(speed: Double?, gusts: Double?, scale: Double) -> some View {
        Group {
            metricBar(total: gusts ?? speed, scale: scale, color: .teal, speed: gusts == nil ? nil : speed)
                .frame(height: metrics.scaled(Theme.Weather.illustrationHeight))
            Text(verbatim: measurement(speed, unit: UnitSpeed.kilometersPerHour))
            Text("Gust \(measurement(gusts, unit: UnitSpeed.kilometersPerHour))")
                .font(metrics.typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func metricBar(
        total: Double?, scale: Double, color: Color, speed: Double? = nil
    ) -> some View {
        let height = metrics.scaled(34)
        let shape = RoundedRectangle(cornerRadius: metrics.radius.keyCap)
        return ZStack(alignment: .bottom) {
            shape.fill(Theme.Colors.controlSurface)
            if let total {
                Rectangle().fill(color.opacity(speed == nil ? 0.75 : 0.35))
                    .frame(height: height * fraction(total, scale: scale))
            }
            if let speed {
                Rectangle().fill(color.opacity(0.75))
                    .frame(height: height * fraction(speed, scale: scale))
            }
        }
        .frame(width: metrics.scaled(20), height: height)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    private func weekly(_ forecast: WeatherForecast, requestedDays: [WeatherDay] = []) -> some View {
        let requestedDay = requestedDays.count == 1 ? requestedDays.first : nil
        let days = weekDays(forecast, requestedDays: requestedDays)
        let weekday = Date.FormatStyle(timeZone: forecast.timeZone).weekday(.abbreviated)
        let dayLabel = requestedDays.isEmpty ? weekday : weekday.day()
        let date = Date.FormatStyle(timeZone: forecast.timeZone).weekday(.wide).month(.abbreviated).day()
        let rainScale = max(1, days.compactMap(\.precipitation).max() ?? 0)
        let windScale = max(10, days.map { max($0.windSpeed ?? 0, $0.windGusts ?? 0) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: metrics.spacing.md) {
            if !requestedDays.isEmpty {
                Text(verbatim: forecast.place)
                    .font(metrics.typography.rowTitle.weight(.semibold))
            }
            if let requestedDay {
                Text(requestedDay.date, format: date)
                    .font(metrics.typography.caption)
                    .foregroundStyle(.secondary)
            }
            metricHeader(period: .week)
            WeatherTimeline(identity: days.first?.date) {
                ForEach(days, id: \.date) { day in
                    Button {
                        var calendar = Calendar(identifier: .gregorian)
                        calendar.timeZone = forecast.timeZone
                        selectedDay = calendar.isDate(day.date, inSameDayAs: forecast.current.time) ? nil : day.date
                        periodOverride = .today
                    } label: {
                    VStack(spacing: metrics.spacing.xs) {
                        Text(day.date, format: dayLabel)
                            .font(metrics.typography.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        dailyValues(day, rainScale: rainScale, windScale: windScale)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity)
                    .frame(width: metrics.scaled(Theme.Weather.hourWidth))
                    .padding(.vertical, metrics.spacing.xs)
                    .background {
                        if day.date == requestedDay?.date {
                            RoundedRectangle(cornerRadius: metrics.radius.row)
                                .fill(Color.accentColor.opacity(0.12))
                        }
                    }
                    .accessibilityElement(children: .combine)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(metrics.typography.rowTitle)
            .monospacedDigit()
        }
    }

    private func weekDays(_ forecast: WeatherForecast, requestedDays: [WeatherDay]) -> [WeatherDay] {
        if query.timing?.week == true || query.timing?.weekend == true, !requestedDays.isEmpty {
            return Array(requestedDays.prefix(7))
        }
        let index = requestedDays.first.flatMap { requested in
            forecast.days.firstIndex { $0.date == requested.date }
        } ?? 0
        let start = max(0, min(index - 3, forecast.days.count - 7))
        return Array(forecast.days.dropFirst(start).prefix(7))
    }

    @ViewBuilder
    private func dailyValues(_ day: WeatherDay, rainScale: Double, windScale: Double) -> some View {
        switch metric {
        case .conditions:
            WeatherIcon(condition: day.condition, size: metrics.scaled(Theme.Weather.hourlyIllustration))
                .accessibilityLabel(Text(conditionTitle(day.condition)))
            HStack(spacing: metrics.spacing.xxs) {
                Text(verbatim: temperature(day.high))
                Text(verbatim: temperature(day.low))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("High \(temperature(day.high)) · Low \(temperature(day.low))"))
        case .rain:
            rainValues(chance: day.precipitationProbability, amount: day.precipitation, scale: rainScale)
        case .wind:
            windValues(speed: day.windSpeed, gusts: day.windGusts, scale: windScale)
        }
    }

    private var attribution: some View {
        HStack(spacing: metrics.spacing.xs) {
            Link(destination: URL(string: "https://open-meteo.com/")!) {
                Text(verbatim: "Open-Meteo")
                    .accessibilityLabel(Text("Forecast data"))
            }
            Text(verbatim: "·").accessibilityHidden(true)
            Link(destination: URL(string: "https://www.amcharts.com/free-animated-svg-weather-icons/")!) {
                Text(verbatim: "amCharts")
                    .accessibilityLabel(Text("Weather icons"))
            }
            Text(verbatim: "·").accessibilityHidden(true)
            Link(destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!) {
                Text(verbatim: "CC BY 4.0")
            }
        }
        .font(metrics.typography.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func conditionTitle(_ condition: WeatherCondition) -> LocalizedStringKey {
        switch condition.code {
        case 0: "Clear"
        case 1: "Mainly clear"
        case 2: "Partly cloudy"
        case 3: "Overcast"
        case 45, 48: "Fog"
        case 51, 53, 55, 56, 57: "Drizzle"
        case 61, 63, 65: "Rain"
        case 66, 67: "Freezing rain"
        case 71, 73, 75, 77, 85, 86: "Snow"
        case 80, 81, 82: "Showers"
        case 95, 96, 97, 99: "Thunderstorm"
        default: "Conditions unavailable"
        }
    }

    private func fraction(_ value: Double, scale: Double) -> Double {
        min(1, max(0, value / scale))
    }

    private func temperature(_ value: Double?) -> String {
        guard let value else { return "—" }
        return Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .narrow, usage: .weather, hidesScaleName: true,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private func percent(_ value: Double?) -> String {
        value.map { ($0 / 100).formatted(.percent.precision(.fractionLength(0))) } ?? "—"
    }

    private func measurement(_ value: Double?, unit: UnitSpeed) -> String {
        guard let value else { return "—" }
        return Measurement(value: value, unit: unit)
            .formatted(.measurement(width: .abbreviated, usage: .wind,
                                    numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    private func measurement<UnitType: Dimension>(
        _ value: Double?, unit: UnitType, fractionDigits: Int = 0
    ) -> String {
        guard let value else { return "—" }
        return Measurement(value: value, unit: unit)
            .formatted(.measurement(
                width: .abbreviated, usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0...fractionDigits))))
    }
}
