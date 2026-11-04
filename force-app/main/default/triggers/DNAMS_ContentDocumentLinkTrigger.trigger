trigger DNAMS_ContentDocumentLinkTrigger on ContentDocumentLink(before insert, after insert, after delete) {
    if (Trigger.isBefore) {
        DNAMS_PackageService.blockLockedLinks(Trigger.new);
    } else if (Trigger.isInsert) {
        DNAMS_PackageService.mirrorElementFilesToPackages(Trigger.new);
    } else {
        DNAMS_PackageService.unmirrorElementFilesFromPackages(Trigger.old);
    }
}