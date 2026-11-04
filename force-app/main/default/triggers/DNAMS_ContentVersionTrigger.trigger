trigger DNAMS_ContentVersionTrigger on ContentVersion(before insert, after insert) {
    if (Trigger.isBefore) {
        DNAMS_PackageService.validateVersions(Trigger.new);
    } else {
        DNAMS_PackageService.linkUploadedVersions(Trigger.new);
    }
}