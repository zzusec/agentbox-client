import Foundation

/// The agentbox server's own wall clock, mirrored on this Mac.
///
/// The instance runs on a server whose clock is usually hours away from the
/// Mac's, and everything the server writes — the web console's usage log, the
/// journal, timestamps the agent prints — is in the server's timezone. The
/// sidebar shows that time so those readings need no arithmetic.
///
/// `/api/me` reports the instant and the configured timezone once; the label
/// then ticks off this Mac's clock plus the measured difference, instead of
/// asking the server once a second. Every resync replaces the difference, so
/// drift and either clock being adjusted both wash out.
struct ServerClock {
    /// The zone the server formats timestamps in (its `config.timezone`).
    let zone: TimeZone
    /// The zone's IANA name, for the label's tooltip.
    let zoneName: String
    /// server − local, measured when the server's time arrived.
    private let offset: TimeInterval

    init?(now: String, timezone: String, localNow: Date = Date()) {
        guard let instant = Self.parse(now) else { return nil }
        // The IANA id keeps DST transitions right; the offset carried by the
        // timestamp only has to cover a zone this Mac's database lacks.
        if let named = TimeZone(identifier: timezone) {
            zone = named
            zoneName = timezone
        } else if let carried = Self.zone(fromOffsetIn: now) {
            zone = carried
            zoneName = timezone.isEmpty ? carried.identifier : timezone
        } else {
            return nil
        }
        offset = instant.timeIntervalSince(localNow)
    }

    func date(at localNow: Date = Date()) -> Date {
        localNow.addingTimeInterval(offset)
    }

    /// "2026-10-02 14:09:12". The date is always there: the server is often on
    /// another date than this Mac, which is the whole reason for showing its
    /// clock, and a bare time would hide exactly that.
    func text(at localNow: Date = Date()) -> String {
        // A fresh formatter per tick: once a second costs nothing, and a shared
        // mutable DateFormatter would not be safe to retime from anywhere else.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date(at: localNow))
    }

    /// RFC 3339, which is what the server's `now` field carries. Go's
    /// time.RFC3339 has no fractional seconds, but accepting them costs one
    /// extra attempt and keeps a future format change from blanking the label.
    private static func parse(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: value)
    }

    /// The trailing "+08:00" / "-07:00" / "Z" of an RFC 3339 timestamp.
    private static func zone(fromOffsetIn value: String) -> TimeZone? {
        if value.hasSuffix("Z") || value.hasSuffix("z") { return TimeZone(secondsFromGMT: 0) }
        let tail = value.suffix(6)
        guard tail.count == 6, let sign = tail.first, sign == "+" || sign == "-" else { return nil }
        let parts = tail.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}

/// The slice of `/api/me` this client reads. Everything else in that response
/// (role, models, quota) belongs to the web console.
struct ServerIdentity: Decodable {
    /// Absent on servers older than v0.1.7-custom22, which simply means no clock.
    let now: String?
    let timezone: String?
    /// The server's release. Absent on older servers; only ever compared with
    /// the last one seen, never with this app's own version — the two are
    /// separate release lines.
    let serverVersion: String?

    enum CodingKeys: String, CodingKey {
        case now, timezone
        case serverVersion = "server_version"
    }
}
