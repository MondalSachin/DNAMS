// Seeds DNAMS_Package_Type_Element_Map__c: one row per Package Type (Global Value Set DNAMS_Package_Type)
// x every DNAMS_Element_Type__c. Only Dealer Application, Address Verification, Photographs of Facility and
// Org Chart are active + required (for every package type); every other row is inactive and not required.
// Re-runnable: upserts on Unique_Key__c (Package Type + ':' + 18-char Element Type Id).
// WARNING: re-running RESETS Is_Active__c / Is_Required__c on every row to the values below, overwriting
// changes admins made on the Package Type Element Maps tab.
// Run: sf apex run -o DNAMS_SDO -f scripts/apex/dnams-seed-package-type-element-map.apex

Set<String> activeRequired = new Set<String>{ 'Dealer Application', 'Address Verification', 'Photographs of Facility', 'Org Chart' };

List<String> packageTypes = new List<String>();
for (Schema.PicklistEntry entry : DNAMS_Package_Type_Element_Map__c.Package_Type__c.getDescribe().getPicklistValues()) {
    if (entry.isActive()) {
        packageTypes.add(entry.getValue());
    }
}

List<DNAMS_Element_Type__c> elementTypes = [SELECT Id, Name FROM DNAMS_Element_Type__c ORDER BY Sort_Order__c ASC NULLS LAST, Name];
Set<String> found = new Set<String>();
for (DNAMS_Element_Type__c elementType : elementTypes) {
    found.add(elementType.Name);
}
for (String name : activeRequired) {
    if (!found.contains(name)) {
        throw new IllegalArgumentException('Element type not found: ' + name);
    }
}

List<DNAMS_Package_Type_Element_Map__c> rows = new List<DNAMS_Package_Type_Element_Map__c>();
for (String packageType : packageTypes) {
    for (DNAMS_Element_Type__c elementType : elementTypes) {
        Boolean isDefault = activeRequired.contains(elementType.Name);
        rows.add(
            new DNAMS_Package_Type_Element_Map__c(
                Unique_Key__c = DNAMSPackageTypeElementMapTriggerHandler.uniqueKey(packageType, elementType.Id),
                Package_Type__c = packageType,
                Element_Type__c = elementType.Id,
                Is_Active__c = isDefault,
                Is_Required__c = isDefault
            )
        );
    }
}
upsert rows Unique_Key__c;

System.debug(
    'Package types: ' + packageTypes.size() + ', element types: ' + elementTypes.size() + ', rows upserted: ' + rows.size() +
    ', total rows: ' + [SELECT COUNT() FROM DNAMS_Package_Type_Element_Map__c] +
    ', active+required: ' + [SELECT COUNT() FROM DNAMS_Package_Type_Element_Map__c WHERE Is_Active__c = TRUE AND Is_Required__c = TRUE]
);
