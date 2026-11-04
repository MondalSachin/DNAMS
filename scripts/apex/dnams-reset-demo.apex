// Deletes every DNAMS package, its review runs, its elements and the files uploaded to them (demo reset).
// Element types are kept. Run: sf apex run -o dnams -f scripts/apex/dnams-reset-demo.apex
List<DNAMS_Package_Element__c> elements = [SELECT Id FROM DNAMS_Package_Element__c];
Set<Id> elementIds = new Map<Id, DNAMS_Package_Element__c>(elements).keySet();
Set<Id> documentIds = new Set<Id>();
if (!elementIds.isEmpty()) {
    for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :elementIds]) {
        documentIds.add(link.ContentDocumentId);
    }
}
delete [SELECT Id FROM AI_Package_Review_Run__c];
delete [SELECT Id FROM ContentDocument WHERE Id IN :documentIds];
delete elements;
List<DNAMS_Package__c> packages = [SELECT Id FROM DNAMS_Package__c];
delete packages;
System.debug('Deleted ' + packages.size() + ' packages, ' + elements.size() + ' elements, ' + documentIds.size() + ' files.');
