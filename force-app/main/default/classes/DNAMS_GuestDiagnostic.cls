public without sharing class DNAMS_GuestDiagnostic {
    public static String report(Id packageId, String token) {
        return 'all=' + [SELECT COUNT() FROM DNAMS_Package__c] +
            ' byId=' + [SELECT COUNT() FROM DNAMS_Package__c WHERE Id = :packageId] +
            ' byToken=' + [SELECT COUNT() FROM DNAMS_Package__c WHERE Upload_Token__c = :token] +
            ' sysAll=' + Database.countQuery('SELECT COUNT() FROM DNAMS_Package__c', AccessLevel.SYSTEM_MODE) +
            ' elements=' + [SELECT COUNT() FROM DNAMS_Package_Element__c];
    }
}