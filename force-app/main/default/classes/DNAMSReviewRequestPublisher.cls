/**
 * @description Publishes DNAMS_Package_Review_Requested__e in system mode.
 *              Dealers submit as the DNAMS Dealer Portal site guest, whose profile has no Create on the event.
 *              From API 67 Apex runs in user mode by default and that publish fails without an exception, so this
 *              class is pinned to API 66.0 (system mode). EventBus.publish has no AccessLevel overload.
 *              Keep this class minimal and on API 66.0.
 **/
public without sharing class DNAMSReviewRequestPublisher {
    /**
     * @description Publishes the review requests (PublishAfterCommit).
     * @param requests Review request events
     * @return         One SaveResult per event, in the same order
     **/
    public static List<Database.SaveResult> publish(List<DNAMS_Package_Review_Requested__e> requests) {
        return EventBus.publish(requests);
    }
}
