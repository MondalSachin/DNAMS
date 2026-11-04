// Runs as the user in PlatformEventSubscriberConfig DNAMS_PackageReviewRequestedConfig (Einstein needs a real user).
trigger DNAMS_PackageReviewRequestedTrigger on DNAMS_Package_Review_Requested__e(after insert) {
    DNAMS_PackageReviewPipelineService.handleReviewRequests(Trigger.new);
}