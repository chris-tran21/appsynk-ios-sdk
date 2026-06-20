import Foundation

/// Attribution result returned by AppSynk after an install / deep link is attributed.
public struct AttributionData: Codable {
    public let channel: String?
    public let campaignName: String?
    public let adSetName: String?
    public let creativeName: String?
    public let medium: String?
    public let source: String?
    /// The ad-network click ID stored after attribution (e.g. ttclid, fbclid, gclid).
    public let clickId: String?
    public let clickTimestamp: Date?
    public let isOrganic: Bool
    public let attributionModel: String?
    public let confidenceScore: Double?
    /// Deferred / deep-link destination configured on the tracking link — route the user here.
    public let deepLink: String?

    public init(
        channel: String? = nil,
        campaignName: String? = nil,
        adSetName: String? = nil,
        creativeName: String? = nil,
        medium: String? = nil,
        source: String? = nil,
        clickId: String? = nil,
        clickTimestamp: Date? = nil,
        isOrganic: Bool = true,
        attributionModel: String? = nil,
        confidenceScore: Double? = nil,
        deepLink: String? = nil
    ) {
        self.channel = channel
        self.campaignName = campaignName
        self.adSetName = adSetName
        self.creativeName = creativeName
        self.medium = medium
        self.source = source
        self.clickId = clickId
        self.clickTimestamp = clickTimestamp
        self.isOrganic = isOrganic
        self.attributionModel = attributionModel
        self.confidenceScore = confidenceScore
        self.deepLink = deepLink
    }

    /// Organic attribution with no channel.
    public static let organic = AttributionData(isOrganic: true)
}
