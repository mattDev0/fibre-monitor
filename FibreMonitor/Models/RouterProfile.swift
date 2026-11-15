import Foundation

/// A saved Huawei ONT connection profile with its own credentials and device aliases.
public struct RouterProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var username: String
    public var lastUsed: Date?
    public var detectedModel: String?
    public var cfgMode: String?

    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        username: String = "root",
        lastUsed: Date? = nil,
        detectedModel: String? = nil,
        cfgMode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.username = username
        self.lastUsed = lastUsed
        self.detectedModel = detectedModel
        self.cfgMode = cfgMode
    }

    /// Pre-filled template for the MTN GNMTNNCE HG8145X6-10 router (password is never prefilled).
    public static func mtnTemplate(id: UUID = UUID()) -> RouterProfile {
        RouterProfile(id: id, name: "New router (MTN)", host: "192.168.2.1", username: "root")
    }
}
