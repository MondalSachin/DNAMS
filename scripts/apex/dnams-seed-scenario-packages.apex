// Demo scenario seed (2026-11-05): 3 demo dealer accounts and 6 Term Renewal packages at Initiated, no files.
// Packages carry their scenario in Demo_Scenario__c and the accounts carry TAG in Description;
// dnams-reset-scenario-packages.apex deletes only that data.
// The demo documents are uploaded by hand; see the scenario sheet for which file goes where.
// Run: sf apex run -o dnams -f scripts/apex/dnams-seed-scenario-packages.apex
final String TAG = 'DNAMS demo scenario seed';
Map<String, Account> accounts = new Map<String, Account>{
    'MATCH' => new Account(Name = 'Ridgeline Northstar of Columbus, LLC', AccountNumber = '40718', Description = TAG,
        BillingStreet = '4825 Morse Road', BillingCity = 'Columbus', BillingState = 'OH', BillingPostalCode = '43230', BillingCountry = 'United States'),
    'NAME_MISMATCH' => new Account(Name = 'Ridgeline Northstar of Columbus, LLC (Demo)', AccountNumber = '40718', Description = TAG,
        BillingStreet = '4825 Morse Road', BillingCity = 'Columbus', BillingState = 'OH', BillingPostalCode = '43230', BillingCountry = 'United States'),
    'WRONG_DEALER' => new Account(Name = 'Northstar Motors Group', AccountNumber = '40999', Description = TAG,
        BillingStreet = '1200 High Street', BillingCity = 'Columbus', BillingState = 'OH', BillingPostalCode = '43215', BillingCountry = 'United States')
};
insert accounts.values();

// Scenario label -> dealer account key (order = the scenario numbers)
List<List<String>> scenarios = new List<List<String>>{
    new List<String>{ '1 - Full pass to transmittal (Green)', 'MATCH' },
    new List<String>{ '2 - Stops at pre-flight (pptx photos)', 'MATCH' },
    new List<String>{ '3 - Stops at classification (bank statement)', 'MATCH' },
    new List<String>{ '4 - Stops at extraction (INCOMPLETE file)', 'MATCH' },
    new List<String>{ '5 - Rule validation Amber, fix name and re-run', 'NAME_MISMATCH' },
    new List<String>{ '6 - Rule validation Red (wrong dealer)', 'WRONG_DEALER' }
};
List<DNAMS_Package__c> packages = new List<DNAMS_Package__c>();
for (List<String> scenario : scenarios) {
    packages.add(new DNAMS_Package__c(Type__c = 'Term Renewal', Status__c = 'Initiated', Buying_Dealer__c = accounts.get(scenario[1]).Id, Demo_Scenario__c = scenario[0]));
}
insert packages;

Map<Id, DNAMS_Package__c> saved = new Map<Id, DNAMS_Package__c>([
    SELECT Id, Name, Package_Name__c, Upload_Token__c, Buying_Dealer__r.Name, (SELECT Id FROM Package_Elements__r) FROM DNAMS_Package__c WHERE Id IN :packages
]);
for (Integer i = 0; i < packages.size(); i++) {
    DNAMS_Package__c pkg = saved.get(packages[i].Id);
    System.debug('SCENARIO ' + scenarios[i][0] + ' | ' + pkg.Name + ' | ' + pkg.Package_Name__c + ' | ' + pkg.Buying_Dealer__r.Name
        + ' | elements ' + pkg.Package_Elements__r.size() + ' | ' + DNAMS_PackageController.uploadLink(pkg.Upload_Token__c));
}
