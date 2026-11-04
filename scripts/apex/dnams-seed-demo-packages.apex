// Creates 12 demo Term Renewal packages at status Initiated (each gets its own 22 new elements and an
// upload token), using existing business accounts (not person accounts) with a dealer code and a contact.
// Element definitions come from custom metadata (DNAMS_Element_Definition__mdt). Run: sf apex run -o dnams -f scripts/apex/dnams-seed-demo-packages.apex
Integer packageCount = 12;
List<DNAMS_Package__c> packages = new List<DNAMS_Package__c>();
for (Account dealer : [
    SELECT Id, (SELECT Id FROM Contacts WHERE Email != null ORDER BY CreatedDate LIMIT 1)
    FROM Account
    WHERE IsPersonAccount = false AND AccountNumber != null AND Id IN (SELECT AccountId FROM Contact WHERE Email != null)
    ORDER BY Name
    LIMIT :packageCount
]) {
    packages.add(
        new DNAMS_Package__c(
            Type__c = 'Term Renewal',
            Status__c = 'Initiated',
            Buying_Dealer__c = dealer.Id,
            Primary_Contact__c = dealer.Contacts[0].Id
        )
    );
}
insert packages;
System.debug('Created ' + packages.size() + ' demo packages.');
