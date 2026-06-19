import SwiftUI

struct ArrivalRowView: View {
    let arrival: Arrival
    let now: Date

    var body: some View {
        HStack(spacing: 12) {

            // Route badge
            Text(arrival.routeShortName)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 36)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule().fill(routeColor))

            // Headsign
            VStack(alignment: .leading, spacing: 2) {
                Text(arrival.headsign ?? "—")
                    .font(.subheadline)
                    .lineLimit(1)
                liveLabel
            }

            Spacer()

            // Time
            Text(arrival.formattedTime(relativeTo: now))
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(timeColor)
                .monospacedDigit()
        }
    }

    // MARK: - Sub-components

    @ViewBuilder
    private var liveLabel: some View {
        if arrival.isLive {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Live")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        } else {
            Text("Scheduled")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var routeColor: Color {
        // In a full implementation we'd pass the color through from RouteInfo.
        // Using accent color as a consistent fallback until colors are wired in.
        .accentColor
    }

    private var timeColor: Color {
        switch arrival.kind {
        case .live(let countdown, _):
            if countdown < 60 { return .red }
            if countdown < 5 * 60 { return .orange }
            return .primary
        case .scheduled:
            return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    let now = Date()
    let arrivals: [Arrival] = [
        Arrival(id: "1", tripId: "T1", routeId: "R1", routeShortName: "30",
                headsign: "Limassol Centre", kind: .live(countdown: 90, vehicleId: "V1")),
        Arrival(id: "2", tripId: "T2", routeId: "R2", routeShortName: "10",
                headsign: "Nicosia Airport", kind: .live(countdown: 7 * 60, vehicleId: nil)),
        Arrival(id: "3", tripId: "T3", routeId: "R3", routeShortName: "5",
                headsign: "Paphos Bus Station",
                kind: .scheduled(clockTime: now.addingTimeInterval(45 * 60)))
    ]
    List(arrivals) { a in
        ArrivalRowView(arrival: a, now: now)
    }
    .listStyle(.plain)
}
