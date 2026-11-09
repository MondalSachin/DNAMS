// Deletes ONLY the demo scenario data created by dnams-seed-scenario-packages.apex: packages with a Demo Scenario label,
// their review runs, elements and uploaded files, then their dealer accounts that carry the seed tag in Description.
// Run: sf apex run -o dnams -f scripts/apex/dnams-reset-scenario-packages.apex
final String TAG = 'DNAMS demo scenario seed';
List<DNAMS_Package__c> packages = [SELECT Id, Buying_Dealer__c FROM DNAMS_Package__c WHERE Demo_Scenario__c != null];
Set<Id> dealerIds = new Set<Id>();
for (DNAMS_Package__c pkg : packages) {
    dealerIds.add(pkg.Buying_Dealer__c);
}
List<Account> accounts = new List<Account>();
for (Account dealer : [SELECT Id, Description FROM Account WHERE Id IN :dealerIds]) {
    if (dealer.Description == TAG) { // Description is long text, so the tag is checked here rather than in SOQL
        accounts.add(dealer);
    }
}
List<DNAMS_Package_Element__c> elements = [SELECT Id FROM DNAMS_Package_Element__c WHERE Package__c IN :packages];
Set<Id> documentIds = new Set<Id>();
if (!elements.isEmpty()) {
    Set<Id> elementIds = new Map<Id, DNAMS_Package_Element__c>(elements).keySet();
    for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId IN :elementIds]) {
        documentIds.add(link.ContentDocumentId);
    }
}
delete [SELECT Id FROM AI_Package_Review_Run__c WHERE Package__c IN :packages];
delete [SELECT Id FROM ContentDocument WHERE Id IN :documentIds];
delete elements;
delete packages;
delete [SELECT Id FROM DNAMS_Package__c WHERE Buying_Dealer__c IN :accounts]; // any other package still on a demo dealer
delete accounts;
System.debug('Deleted ' + packages.size() + ' packages, ' + elements.size() + ' elements, ' + documentIds.size() + ' files, ' + accounts.size() + ' accounts.');
