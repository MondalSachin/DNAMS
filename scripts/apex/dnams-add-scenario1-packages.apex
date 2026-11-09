// Adds 6 more scenario 1 (full pass to transmittal, Green) packages on the existing demo dealer
// "Ridgeline Northstar of Columbus, LLC" (the MATCH account created by dnams-seed-scenario-packages.apex).
// Term Renewal, Initiated, no files; dnams-reset-scenario-packages.apex deletes them with the rest of the demo data.
// Run: sf apex run -o dnams -f scripts/apex/dnams-add-scenario1-packages.apex
final String TAG = 'DNAMS demo scenario seed';
final Integer EXTRA = 6;
Account dealer;
for (Account candidate : [SELECT Id, Description FROM Account WHERE Name = 'Ridgeline Northstar of Columbus, LLC' AND AccountNumber = '40718']) {
    if (candidate.Description == TAG) {
        dealer = candidate;
    }
}
if (dealer == null) {
    throw new IllegalArgumentException('Demo dealer not found: run dnams-seed-scenario-packages.apex first.');
}
Integer existing = [SELECT COUNT() FROM DNAMS_Package__c WHERE Demo_Scenario__c LIKE '1 - Full pass to transmittal (Green)%'];
List<DNAMS_Package__c> packages = new List<DNAMS_Package__c>();
for (Integer i = 1; i <= EXTRA; i++) {
    packages.add(new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = dealer.Id,
        Demo_Scenario__c = '1 - Full pass to transmittal (Green) #' + (existing + i)));
}
insert packages;
for (DNAMS_Package__c pkg : [
    SELECT Name, Demo_Scenario__c, Upload_Token__c, (SELECT Id FROM Package_Elements__r) FROM DNAMS_Package__c WHERE Id IN :packages ORDER BY Name
]) {
    System.debug('SCENARIO ' + pkg.Demo_Scenario__c + ' | ' + pkg.Name + ' | elements ' + pkg.Package_Elements__r.size()
        + ' | ' + DNAMS_PackageController.uploadLink(pkg.Upload_Token__c));
}
