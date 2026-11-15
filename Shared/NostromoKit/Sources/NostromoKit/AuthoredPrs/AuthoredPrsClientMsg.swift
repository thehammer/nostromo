import Foundation

/// `{"type":"authored_prs_demand","level":"visible"|"hidden"|"idle"}`: who is looking at the PR list.
/// Honoured by the daemon only from the verified operator app.
public struct ClientAuthoredPrsDemand: Encodable, Equatable {
    let type_: String = "authored_prs_demand"
    public let level: String
    public init(level: String) { self.level = level }
    enum CodingKeys: String, CodingKey { case type_ = "type", level }
}

/// `{"type":"authored_prs_refresh"}`: ask for a full reconcile now.
public struct ClientAuthoredPrsRefresh: Encodable, Equatable {
    let type_: String = "authored_prs_refresh"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}
