trigger DNAMS_PackageTrigger on DNAMS_Package__c(before insert, before update, after insert, after update) {
    if (Trigger.isBefore) {
        DNAMS_PackageService.beforeSave(Trigger.new, Trigger.oldMap);
    } else {
        DNAMS_PackageService.afterSave(Trigger.new, Trigger.oldMap);
    }
}